import ControllerPackage
import Darwin
import FileRouting
import Foundation
import PaneModel
import ProcessInspection
import ScriptWire

/// A native controller's launch, between the command's request and the entry's own connection.
///
/// The command asks for the run, the app verifies and snapshots the package, and the command then
/// execs the snapshot's entry in the same process. The entry's connection is bound to the run only
/// when it comes from that process, with the same start time, after an exec, running the very code
/// the snapshot holds at the snapshot's path.
struct NativeLaunch {
  let snapshot: ControllerSnapshot
  let scopes: Set<ControllerPermission>
  let started: Int

  /// The command's process ID version. The entry's must differ, since an exec changes it.
  let launcherGeneration: Int32

  /// The entry's code directory hash and path, read from the snapshot.
  let entryHash: Data
  let entryPath: String

  let sourceRoot: ProcessIdentity?
  let window: UInt64?
  let pane: NodeID?

  /// The entry's process ID version, once its first connection is bound.
  var generation: Int32?

  let watch: any DispatchSourceProcess
}

extension ScriptHost {
  /// The most native launches the host tracks at once. Each one waits on a process that the
  /// listener already counts as a connection, so the bound matches the listener's.
  static let maxNativeLaunches = ScriptListener.maxConnections

  /// The run a connection is bound to, or nil when it is no controller run.
  public func controllerRun(connection id: UInt64) -> ControllerRun? {
    controllerRuns[id]
  }

  /// Every live controller run, oldest connection first.
  public func allControllerRuns() -> [ControllerRun] {
    controllerRuns.values.sorted { $0.connection < $1.connection }
  }

  /// Starts the admission of a controller run. Nothing the connection sends is answered until the
  /// app has authenticated the command, verified the package, and made its snapshot, all off the
  /// main actor.
  func beginController(_ connection: ScriptConnection, _ request: ControllerBegin) {
    guard let settings = controllerSettings else {
      return refuseController(connection, "This uniterm does not run controller packages.")
    }

    guard let token = connection.peer.token else {
      return refuseController(connection, "uniterm cannot tell which program asked.")
    }

    guard request.package.hasPrefix("/") else {
      return refuseController(connection, "The package must be named by an absolute path.")
    }

    if request.entry == .native, nativeLaunches.count >= Self.maxNativeLaunches {
      return refuseController(connection, "Too many native controllers are starting at once.")
    }

    controllerAdmissions.insert(connection.id)

    Task { @MainActor [weak self] in
      let outcome = await Task.detached {
        Self.admit(request, token: token, settings: settings)
      }.value

      self?.finishController(connection, request, outcome: outcome)
    }
  }

  /// What admission found, off the main actor.
  enum Admission: Sendable {
    case admitted(ControllerSnapshot, entryHash: Data?, entryPath: String?)
    case refused(String)
  }

  nonisolated static func admit(
    _ request: ControllerBegin, token: AuditToken, settings: ControllerSettings
  ) -> Admission {
    if let refusal = settings.helper.refusal(forPeer: token) { return .refused(refusal) }

    let snapshot: ControllerSnapshot

    do {
      snapshot = try ControllerSnapshot.create(from: request.package, in: settings.runsRoot)
    } catch {
      return .refused("uniterm refused the controller: \(error)")
    }

    let descriptor = snapshot.controller.descriptor
    let wanted: ControllerEntryKind = request.entry == .janet ? .janet : .native

    guard descriptor.entryKind == wanted else {
      snapshot.remove()

      return .refused(
        wanted == .janet
          ? "This package's entry is native. Run it with uniterm controller run."
          : "This package's entry is Janet. Run it with uniterm run.")
    }

    if let undeclared = request.capabilities.first(where: { !descriptor.capabilities.contains($0) })
    {
      snapshot.remove()

      return .refused(
        "--allow \(undeclared) is not a capability the controller declares, so it cannot be "
          + "granted.")
    }

    guard wanted == .native else { return .admitted(snapshot, entryHash: nil, entryPath: nil) }

    guard let entry = CodeIdentity.ofFile(at: snapshot.entryURL),
      let path = realpath(snapshot.entryURL.path)
    else {
      snapshot.remove()

      return .refused(
        "The native entry has no valid code signature, so uniterm cannot tell it runs.")
    }

    return .admitted(snapshot, entryHash: entry.codeDirectoryHash, entryPath: path)
  }

  private func finishController(
    _ connection: ScriptConnection, _ request: ControllerBegin, outcome: Admission
  ) {
    controllerAdmissions.remove(connection.id)

    let snapshot: ControllerSnapshot

    switch outcome {
    case .refused(let text):
      return refuseController(connection, text)

    case .admitted(let made, _, _):
      snapshot = made
    }

    // The command may have exited, started another executable, or been revoked while the package
    // was read. Its run then never starts.
    guard !connection.isClosed, connection.peerGenerationHolds,
      !isRevoked(connection.id), let token = connection.peer.token
    else {
      snapshot.remove()

      return refuseController(connection, "The program that asked for the run is gone.")
    }

    let descriptor = snapshot.controller.descriptor
    var scopes = Set(request.capabilities.map(ControllerPermission.capability))

    if descriptor.permissions.contains(.paneControl) { scopes.insert(.paneControl) }

    let caller = caller(for: connection)

    if case .admitted(_, let hash?, let path?) = outcome {
      startNativeLaunch(
        NativeLaunch(
          snapshot: snapshot, scopes: scopes, started: connection.peerStartTime,
          launcherGeneration: token.pidVersion, entryHash: hash, entryPath: path,
          sourceRoot: connection.binding?.root, window: caller?.window, pane: caller?.pane,
          generation: nil, watch: watchNative(connection.peer.pid)),
        pid: connection.peer.pid)
    } else {
      controllerRuns[connection.id] = ControllerRun(
        identity: snapshot.controller.identity, name: descriptor.name,
        entryKind: descriptor.entryKind, entryPath: descriptor.entryPath, scopes: scopes,
        pid: connection.peer.pid, generation: token.pidVersion, connection: connection.id,
        sourceRoot: connection.binding?.root, window: caller?.window, pane: caller?.pane,
        snapshot: snapshot.directory)
      controllerSnapshots[connection.id] = snapshot.directory
      sessions[connection.id, default: Session()].name = Self.label(for: descriptor.name)
    }

    connection.send(
      .controllerAdmitted(
        snapshot: snapshot.directory.path, version: snapshot.controller.descriptor.versionDigest))
    controllersChanged()
  }

  private func refuseController(_ connection: ScriptConnection, _ text: String) {
    connection.send(.controllerRefused(text))
    connection.closeAfterSending()
  }

  private func startNativeLaunch(_ launch: NativeLaunch, pid: pid_t) {
    if let earlier = nativeLaunches.removeValue(forKey: pid) { endNativeLaunch(earlier, pid: pid) }

    nativeLaunches[pid] = launch
    launch.watch.activate()
  }

  /// Watches a native controller's process. Its first exec is the command starting the entry.
  /// Any later one, or its exit, ends the run and removes the snapshot.
  private func watchNative(_ pid: pid_t) -> any DispatchSourceProcess {
    let watch = DispatchSource.makeProcessSource(
      identifier: pid, eventMask: [.exec, .exit], queue: .main)

    watch.setEventHandler { [weak self] in
      MainActor.assumeIsolated { self?.nativeProcessChanged(pid) }
    }

    return watch
  }

  private func nativeProcessChanged(_ pid: pid_t) {
    guard let launch = nativeLaunches[pid] else { return }

    let running = ProcessInspection.isRunning(pid: pid, started: launch.started)

    if running, launch.generation == nil { return }

    // An exec notice can arrive after the entry's connection was bound. Its connections then
    // still hold their generation, and the notice is the one that started the entry.
    let connections = controllerRuns.values.filter { $0.pid == pid }.compactMap {
      listener.findConnection($0.connection)
    }

    if running, connections.contains(where: { $0.peerGenerationHolds }) { return }

    nativeLaunches[pid] = nil
    endNativeLaunch(launch, pid: pid)
  }

  private func endNativeLaunch(_ launch: NativeLaunch, pid: pid_t) {
    launch.watch.cancel()

    for run in controllerRuns.values
    where run.pid == pid && run.snapshot == launch.snapshot.directory {
      controllerRuns[run.connection] = nil
      authorityEnded(run.connection)
    }

    launch.snapshot.remove()
  }

  /// Binds a new connection to the native launch it comes from, when it does. A connection from
  /// the command itself, from another process at a reused ID, or from code that is not the
  /// snapshot's entry gets no run.
  ///
  /// It runs on the main actor, before the connection's first call, so that call already has its
  /// run. The code check asks only for the running code's dynamic signing information, and no
  /// check of the file on disk. The entry's hash was read off the main actor at admission.
  func adoptNativeRun(_ connection: ScriptConnection) {
    let pid = connection.peer.pid

    guard var launch = nativeLaunches[pid], let token = connection.peer.token,
      connection.peerStartTime == launch.started,
      token.pidVersion != launch.launcherGeneration,
      launch.generation == nil || launch.generation == token.pidVersion,
      let running = CodeIdentity.ofProcess(token: token, dynamicOnly: true),
      running.codeDirectoryHash == launch.entryHash,
      let path = running.path.flatMap(realpath), path == launch.entryPath,
      connection.peerGenerationHolds
    else { return }

    launch.generation = token.pidVersion
    nativeLaunches[pid] = launch

    let descriptor = launch.snapshot.controller.descriptor

    controllerRuns[connection.id] = ControllerRun(
      identity: launch.snapshot.controller.identity, name: descriptor.name,
      entryKind: .native, entryPath: descriptor.entryPath, scopes: launch.scopes, pid: pid,
      generation: token.pidVersion, connection: connection.id, sourceRoot: launch.sourceRoot,
      window: launch.window, pane: launch.pane, snapshot: launch.snapshot.directory)
    sessions[connection.id, default: Session()].name = Self.label(for: descriptor.name)
    controllersChanged()
  }

  /// The refusal for a call a controller run may not make, or nil. A run waiting for admission
  /// may make none. A run that did not declare pane control may only post status.
  func controllerRefusal(for call: ScriptCall, on connection: ScriptConnection) -> ScriptResult? {
    if controllerAdmissions.contains(connection.id) {
      return .failure(.refused, "uniterm has not admitted this controller yet.")
    }

    guard let run = controllerRuns[connection.id] else { return nil }

    guard run.generation == connection.peer.token?.pidVersion, connection.peerGenerationHolds
    else {
      return .failure(.refused, "This controller run has ended.")
    }

    if case .postStatus = call { return nil }

    guard run.declaresPaneControl else {
      return .failure(
        .refused,
        "This controller did not declare pane-control in its controller.json, so it cannot act "
          + "on panes.")
    }

    return nil
  }

  /// Ends a connection's run when the connection goes, and removes a Janet run's snapshot. A
  /// native run's snapshot stays while its process runs from it.
  func controllerConnectionClosed(_ id: UInt64) {
    controllerAdmissions.remove(id)
    controllerRuns[id] = nil

    if let snapshot = controllerSnapshots.removeValue(forKey: id) {
      ControllerSnapshot.remove(directory: snapshot)
    }
  }

  /// Ends the runs of revoked connections. A Janet run's snapshot stays until its connection
  /// closes. Remembered trust, which a later milestone keeps, is a separate thing and is not
  /// touched.
  func controllerRunsRevoked(_ ids: Set<UInt64>) {
    for id in ids { controllerRuns[id] = nil }
  }

  /// Ends every run and removes every snapshot, as the host stops.
  func stopControllers() {
    for (pid, launch) in nativeLaunches { endNativeLaunch(launch, pid: pid) }

    nativeLaunches = [:]

    for snapshot in controllerSnapshots.values { ControllerSnapshot.remove(directory: snapshot) }

    controllerSnapshots = [:]
    controllerRuns = [:]
    controllerAdmissions = []
  }
}

private func realpath(_ path: String) -> String? {
  guard let resolved = Darwin.realpath(path, nil) else { return nil }

  defer { free(resolved) }

  return String(cString: resolved)
}
