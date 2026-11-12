import ControllerPackage
import Foundation
import PaneModel
import ProcessInspection
import ScriptWire
import StatusKit

/// The main actor's side of scripting. It answers each call a connected script makes, and never
/// waits on a peer.
///
/// A script's status messages post through a producer that this app issued, so a script never
/// posts as uniterm. The producer's name is the script's, which the user can read in the history.
@MainActor
public final class ScriptHost {
  /// Issues a script producer, or nil when no window can show one.
  public typealias ProducerIssuer = @MainActor (_ name: String) -> StatusProducer?

  /// The longest producer name shown, in UTF-8 bytes.
  static let maxLabelBytes = 64

  struct Session {
    var name = "script"
    var producer: StatusProducer?

    /// The connection presented a token the host turned away. Nothing it sends is answered.
    var refused = false
  }

  let listener: ScriptListener
  private let issueProducer: ProducerIssuer
  private let windows: (any ScriptWindowAPI)?
  private let sentContent: ScriptSentContent?
  let onRefusal: @MainActor (ScriptRefusal) -> Void
  var sessions: [UInt64: Session] = [:]

  /// The REPL channels whose token no helper has spent yet, by token.
  var pendingRepls: [Data: ScriptReplChannel] = [:]

  /// The REPL channel each connection is bound to, by connection.
  var boundRepls: [UInt64: ScriptReplChannel] = [:]

  let reaper: ProcessReaper

  /// What bounds a REPL helper, and how the app reads its footprint and the time.
  let replLimits: ReplLimits
  let replProbes: ReplProbes
  var monitor: Task<Void, Never>?
  var lastSample: ContinuousClock.Instant?

  /// True from the first refusal for the budget until the total is back under it. One warning is
  /// recorded for the episode, however many panes are refused.
  var budgetEpisodeAnnounced = false

  /// Tracks spawned terminal session roots for authority checking.
  public let sessionRoots = SessionRootRegistry()

  /// The file each pane holds from a script's send. It is the only one the pane may still read.
  private struct Held {
    var file: URL
    var size: Int
  }

  private struct PaneKey: Hashable {
    var window: UInt64
    var pane: UInt64
  }

  private var held: [PaneKey: Held] = [:]
  private var task: Task<Void, Never>?

  /// The requests of unbound connections that the user has not answered, oldest first. A
  /// connection holds at most one, so its repeated calls coalesce. Each connection holds one of
  /// the listener's slots, so the list never passes the listener's limit.
  private var pendingRequests: [PendingRequest] = []

  /// The most requests that wait at once.
  static let maxPendingRequests = ScriptListener.maxConnections

  /// The connections whose request the user denied, or whose grant the user revoked. Their calls
  /// stay refused and are not asked about again. A reconnect is a new connection, so it asks again.
  private var declined: Set<UInt64> = []

  /// The session roots running in each pane, oldest first. A terminal pane holds one per tab. Only
  /// this table says which pane a root belongs to, so a grant names a pane and gets its root here.
  private var paneRoots: [PaneKey: [ProcessIdentity]] = [:]

  /// The grants the user made, by connection. A grant binds one connection to one pane's session.
  private var grants: [UInt64: ExplicitGrant] = [:]

  /// REPL helpers that presented a valid token before their pane's session root arrived, by
  /// connection. The attach completes or is refused once the root is known.
  var awaitingRoot: [UInt64: (connection: ScriptConnection, channel: ScriptReplChannel)] = [:]

  /// The connections whose control the user revoked. Their calls stay refused for as long as they
  /// stay connected, even when they still run in a remote-controlled pane.
  private var revokedControllers: Set<UInt64> = []

  /// A watch on each connection's peer process, by connection. It reports an exec or an exit as
  /// it happens, so a connection whose peer started another executable loses its authority at
  /// once, and not only at its next call.
  private var peerWatches: [UInt64: any DispatchSourceProcess] = [:]

  /// Where controller snapshots live and how the bundle's command is known. Without it, every
  /// controller run is refused.
  let controllerSettings: ControllerSettings?

  /// The admitted controller runs, by the connection each is bound to.
  var controllerRuns: [UInt64: ControllerRun] = [:]

  /// The snapshot of each Janet run, by connection. It outlives the run's authority, which a revoke
  /// ends, and goes when the connection closes, since the helper may still load from it until then.
  var controllerSnapshots: [UInt64: URL] = [:]

  /// Connections that asked for a controller run the host has not answered yet.
  var controllerAdmissions: Set<UInt64> = []

  /// Native controller launches, by the process that runs them.
  var nativeLaunches: [pid_t: NativeLaunch] = [:]

  /// Runs with a connection's ID when its authority to control panes ends: it closed, the user
  /// revoked it, or its binding to a pane ended. The window layer takes away every group it owns.
  /// It may run more than once for one connection.
  public var onControllerEnded: ((UInt64) -> Void)?

  /// Runs whenever a connection starts or stops acting for a pane: a binding through ancestry, a
  /// grant, a REPL attach, or any end of one. Pane chrome that names controllers reads them again.
  public var onControllersChanged: (() -> Void)?

  /// Runs when a request or a grant appears or goes away.
  public var onPendingRequestsChanged: (() -> Void)?

  /// Runs with true while any request waits, and with false once none does.
  public var onPendingRequestsActiveChanged: ((Bool) -> Void)?

  /// A request from a connection that is in no uniterm pane. It names the program, so the user can
  /// tell what is asking.
  public struct PendingRequest: Identifiable, Sendable, Equatable {
    public let id: UInt64
    public let pid: pid_t
    public let executablePath: String?
    public let name: String
    public let timestamp: Date
  }

  /// One connection's grant: the pane the user chose, and the session it was running when the
  /// user chose it.
  public struct ExplicitGrant: Sendable, Equatable {
    public let connection: UInt64
    public let pid: pid_t
    public let executablePath: String?
    public let window: UInt64
    public let pane: NodeID
    public let root: ProcessIdentity
    public let generation: UInt64
    public let grantedAt: Date
  }

  /// What came of the user's grant.
  public enum GrantResult: Equatable, Sendable {
    case granted

    /// The program left before the grant, so there is nothing to grant.
    case connectionClosed

    /// The grant was not made. The text says why, for the user.
    case failed(String)
  }

  /// Without `windows` or `sentContent`, the calls that need them are refused.
  public init(
    listener: ScriptListener, issueProducer: @escaping ProducerIssuer,
    windows: (any ScriptWindowAPI)? = nil, sentContent: ScriptSentContent? = nil,
    onRefusal: @escaping @MainActor (ScriptRefusal) -> Void = { _ in },
    reaper: ProcessReaper = .live, replLimits: ReplLimits = .live,
    replProbes: ReplProbes = .live, controllers: ControllerSettings? = nil
  ) {
    self.controllerSettings = controllers
    self.reaper = reaper
    self.replLimits = replLimits
    self.replProbes = replProbes
    self.listener = listener
    self.issueProducer = issueProducer
    self.windows = windows
    self.sentContent = sentContent
    self.onRefusal = onRefusal
  }

  /// The address of this instance, which no other instance shares. A REPL's helper takes it, so
  /// the helper reaches the instance that started it and not another one that is running.
  public var instanceAddress: String { listener.path }

  public func start() {
    guard task == nil else { return }

    let events = listener.events

    task = Task { [weak self] in
      for await event in events {
        self?.handle(event)
      }
    }

    startMonitor()
  }

  public func stop() {
    listener.stop()
    task?.cancel()
    task = nil
    monitor?.cancel()
    monitor = nil

    for session in sessions.values {
      session.producer?.retire()
    }

    sessions = [:]
    stopControllers()

    for watch in peerWatches.values { watch.cancel() }

    peerWatches = [:]
    pendingRepls = [:]
    boundRepls = [:]
    awaitingRoot = [:]
    pendingRequests = []
    declined = []
    grants = [:]
    revokedControllers = []
  }

  func handle(_ event: ScriptEvent) {
    switch event {
    case .begun(let connection, let name):
      sessions[connection.id, default: Session()].name = Self.label(for: name)

      watchPeer(of: connection)
      bindConnection(connection)
      adoptNativeRun(connection)

    case .controllerBegun(let connection, let request):
      sessions[connection.id, default: Session()].name = "controller"

      watchPeer(of: connection)
      bindConnection(connection)
      beginController(connection, request)

    case .attached(let connection, let token):
      watchPeer(of: connection)
      attach(connection, token: token)

    case .replLine(let connection, let text):
      boundRepls[connection.id]?.onEvent?(.line(text))

      if boundRepls[connection.id] == nil { connection.close() }

    case .replEvaluating(let connection, let running):
      boundRepls[connection.id]?.evaluationChanged(running)

      if boundRepls[connection.id] == nil { connection.close() }

    case .pong(let connection, let nonce):
      boundRepls[connection.id]?.pong(nonce, now: replProbes.now())

    case .replMemoryLimit(let connection):
      boundRepls[connection.id]?.helperReachedMemoryLimit()

      if boundRepls[connection.id] == nil { connection.close() }

    case .request(let connection, let id, let call):
      guard sessions[connection.id]?.refused != true, !connection.isClosed else { return }

      releaseFilesOfClosedPanes()

      switch call {
      case .openPane, .openTab, .sendCommand, .requestLayout:
        Task { @MainActor [weak self] in
          let result =
            await self?.runAsync(call, connection: connection)
            ?? .failure(.refused, "uniterm is quitting")

          connection.reply(id: id, result: result)
        }

      default:
        connection.reply(id: id, result: run(call, on: connection))
      }

    case .closed(let connection):
      peerWatches.removeValue(forKey: connection.id)?.cancel()
      controllerConnectionClosed(connection.id)
      sessions[connection.id]?.producer?.retire()
      sessions[connection.id] = nil
      boundRepls.removeValue(forKey: connection.id)?.connectionClosed()
      awaitingRoot[connection.id] = nil
      declined.remove(connection.id)
      revokedControllers.remove(connection.id)
      forget(connection: connection.id)
      authorityEnded(connection.id)

    case .refused(_, let refusal):
      onRefusal(refusal)
    }
  }

  private func run(_ call: ScriptCall, on connection: ScriptConnection) -> ScriptResult {
    if let refusal = authorize(connection) { return refusal }

    if let refusal = controllerRefusal(for: call, on: connection) { return refusal }

    switch call {
    case .postStatus(let level, let text):
      guard let producer = producer(for: connection) else {
        return .failure(.refused, "uniterm has no window to show the message")
      }

      producer.post(level: Self.level(level), text: text)

      return .ok(Data())

    case .listWindows:
      return answer { try requireWindows().listWindows(caller: try requireCaller(connection)) }

    case .listPanes(let window):
      return answer {
        try requireWindows().listPanes(window: window, caller: try requireCaller(connection))
      }

    case .openPane, .openTab, .sendCommand, .requestLayout:
      return .failure(.failed, "the call needs to wait, and was run as if it did not")

    case .send(let target, let name, let content):
      return answer {
        try send(content, named: name, to: target, caller: try requireCaller(connection))
      }
    }
  }

  /// The calls that check a directory run off the main actor and answer later.
  private func runAsync(_ call: ScriptCall, connection: ScriptConnection) async -> ScriptResult {
    if let refusal = authorize(connection) { return refusal }

    if let refusal = controllerRefusal(for: call, on: connection) { return refusal }

    do {
      let caller = try requireCaller(connection)

      // A call that waits keeps the caller it started with. A connection that came to act for
      // another pane meanwhile is refused, so the call never runs with authority it no longer has.
      let stillAllowed: @MainActor () throws -> Void = {
        try self.requireAuthority(connection)

        if case .failure(let kind, let text)? = self.controllerRefusal(for: call, on: connection) {
          throw ScriptCallError(kind, text)
        }

        guard try self.requireCaller(connection) == caller else {
          throw ScriptCallError.refused("This program no longer acts for the pane it called from.")
        }
      }

      switch call {
      case .openPane(let kind, let beside, let axis, let directory, let access):
        return Self.result(
          of: try await requireWindows().openPane(
            kind: kind, beside: beside, axis: axis, directory: directory, access: access,
            caller: caller, stillAllowed: stillAllowed))

      case .openTab(let pane, let directory):
        return Self.result(
          of: try await requireWindows().openTab(
            pane: pane, directory: directory, caller: caller, stillAllowed: stillAllowed))

      case .sendCommand(let pane, let type, let version, let command, let arguments):
        return Self.result(
          of: try await requireWindows().sendCommand(
            to: pane, appletType: type, schemaVersion: version, command: command,
            arguments: arguments, caller: caller, stillAllowed: stillAllowed),
          commandRan: true)

      case .requestLayout(let pane, let layout):
        return Self.result(
          of: try await requireWindows().requestLayout(
            anchor: pane, layout: layout, caller: caller, stillAllowed: stillAllowed),
          commandRan: true)

      default:
        return .failure(.failed, "the call does not wait")
      }
    } catch {
      return Self.failure(error)
    }
  }

  /// The refusal for a call the connection may not make, or nil when it may. An unbound connection
  /// is asked about once. A binding is checked again on every call, so a peer that exited, or a
  /// session that closed, takes its authority with it.
  private func authorize(_ connection: ScriptConnection) -> ScriptResult? {
    if peerWasReplaced(connection) {
      peerReplaced(connection)

      return .failure(
        .refused,
        "The program that opened this connection has since started another executable, or handed "
          + "the connection on, so the connection has no authority. It must reconnect.")
    }

    if revokedControllers.contains(connection.id) {
      return .failure(
        .refused,
        "You revoked this program's control of uniterm panes. It must reconnect to try again.")
    }

    guard connection.isBound else {
      // A REPL helper waiting for its session root is not a program to ask about. It binds to its
      // own pane or not at all.
      if awaitingRoot[connection.id] != nil {
        return .failure(.refused, "This REPL is not attached to its pane yet.")
      }

      if declined.contains(connection.id) {
        return .failure(.refused, "You denied this program access to a uniterm pane.")
      }

      recordPendingRequest(for: connection)

      return .failure(
        .refused,
        "This program is not running in a uniterm pane. Grant it a pane from Window > Pending "
          + "Requests.")
    }

    guard connection.validateBinding(registry: sessionRoots) else {
      endGrants { $0.connection == connection.id }
      authorityEnded(connection.id)

      return .failure(.refused, "The session this program was running in has closed.")
    }

    // A binding found through ancestry lasts only while the ancestry does. A process whose parent
    // exited has been moved to launchd, so it now asks like any program outside the panes. A
    // grant is the user's answer for that connection, so it needs no ancestry.
    if grants[connection.id] == nil, let binding = connection.binding {
      let peer = ProcessIdentity(pid: connection.peer.pid, started: connection.peerStartTime)

      guard ProcessAncestry.findRoot(for: peer, in: sessionRoots) == binding.root else {
        connection.unbind()
        authorityEnded(connection.id)

        return authorize(connection)
      }
    }

    return nil
  }

  /// Watches the connection's peer for an exec or an exit. The watch only hurries the end along.
  /// Every call checks the peer's generation itself, so an event that arrives late changes nothing.
  private func watchPeer(of connection: ScriptConnection) {
    guard peerWatches[connection.id] == nil else { return }

    let watch = DispatchSource.makeProcessSource(
      identifier: connection.peer.pid, eventMask: [.exec, .exit], queue: .main)

    watch.setEventHandler { [weak self, weak connection] in
      MainActor.assumeIsolated {
        guard let self, let connection, !connection.isClosed, self.peerWasReplaced(connection)
        else { return }

        self.peerReplaced(connection)
      }
    }

    peerWatches[connection.id] = watch
    watch.activate()

    // An exec that came before the watch started raised no event, so the generation is read once
    // the watch is in place.
    if peerWasReplaced(connection) { peerReplaced(connection) }
  }

  /// True when the process the connection admitted still runs but is no longer what speaks on it:
  /// it started another executable, or a process it forked has taken the socket over. A peer that
  /// exited is not counted here. Its binding fails on its own, as a closed session's does.
  private func peerWasReplaced(_ connection: ScriptConnection) -> Bool {
    !connection.peerGenerationHolds
      && ProcessInspection.isRunning(pid: connection.peer.pid, started: connection.peerStartTime)
  }

  /// Ends everything a connection could do once its peer is no longer the process it admitted.
  /// Its binding, grant, request, controller run, and owned groups go at once. A Janet run's
  /// snapshot stays until the connection closes. Every call it makes after that is
  /// refused, including one it sent before the exec, since each call reads the generation again.
  private func peerReplaced(_ connection: ScriptConnection) {
    endGrants { $0.connection == connection.id }
    forget(connection: connection.id)

    if connection.isBound { connection.unbind() }

    declined.insert(connection.id)
    controllerRuns[connection.id] = nil
    authorityEnded(connection.id)
  }

  /// Throws the refusal `authorize` gives. A call that waits checks again after the wait, since
  /// a grant, a session, or the peer itself can end while it waits.
  private func requireAuthority(_ connection: ScriptConnection) throws {
    guard case .failure(let kind, let text)? = authorize(connection) else { return }

    throw ScriptCallError(kind, text)
  }

  /// The pane a bound connection acts for: the pane of its grant, or the pane whose session root
  /// its ancestry leads to. Nil when the root is in no pane the host knows.
  func caller(for connection: ScriptConnection) -> ScriptCaller? {
    if let grant = grants[connection.id] {
      return ScriptCaller(connection: connection.id, window: grant.window, pane: grant.pane)
    }

    guard let root = connection.binding?.root,
      let key = paneRoots.first(where: { $0.value.contains(root) })?.key
    else { return nil }

    return ScriptCaller(
      connection: connection.id, window: key.window, pane: NodeID(rawValue: key.pane))
  }

  private func requireCaller(_ connection: ScriptConnection) throws -> ScriptCaller {
    guard let caller = caller(for: connection) else {
      throw ScriptCallError.refused("uniterm cannot tell which pane this program acts for.")
    }

    return caller
  }

  func isRevoked(_ id: UInt64) -> Bool {
    revokedControllers.contains(id)
  }

  func authorityEnded(_ id: UInt64) {
    onControllerEnded?(id)
    controllersChanged()
  }

  func controllersChanged() {
    onControllersChanged?()
  }

  // MARK: Controllers

  /// The connections that act for a pane now: those whose grant names it, and those whose
  /// ancestry leads to one of its session roots.
  public func controllers(actingFrom window: UInt64, pane: NodeID) -> Set<UInt64> {
    controllers { $0.window == window && $0.pane == pane }
  }

  /// The connections that act for any pane of a window now, leaving out the ones the user
  /// revoked, since their calls are refused.
  public func controllers(actingIn window: UInt64) -> Set<UInt64> {
    controllers { $0.window == window }.subtracting(revokedControllers)
  }

  private func controllers(where matches: (ScriptCaller) -> Bool) -> Set<UInt64> {
    var found = Set<UInt64>()

    for id in sessions.keys {
      guard let connection = findConnection(id), !connection.isClosed,
        let caller = caller(for: connection), matches(caller)
      else { continue }

      found.insert(id)
    }

    return found
  }

  /// Ends the control of each connection. Its calls are refused from now on, including calls it
  /// sent that the host has not read or that wait in a directory check. Its grant ends, and it is
  /// not asked about again. The window layer is told, so the groups it owns lose their owner.
  public func revokeControllers(_ ids: Set<UInt64>) {
    controllerRunsRevoked(ids)

    for id in ids {
      revokedControllers.insert(id)
      endGrants { $0.connection == id }
      declined.insert(id)
      authorityEnded(id)
    }
  }

  /// What pane chrome calls a connection: its script's name and its program's PID. Nil for a
  /// connection that is gone.
  public func controllerName(_ id: UInt64) -> String? {
    guard let connection = findConnection(id), !connection.isClosed else { return nil }

    let name = sessions[id]?.name ?? "script"

    if let run = controllerRuns[id] {
      return "\(name), controller \(run.identity.controllerID) (PID \(connection.peer.pid))"
    }

    return "\(name) (PID \(connection.peer.pid))"
  }

  private func requireWindows() throws -> any ScriptWindowAPI {
    guard let windows else { throw ScriptCallError.refused("uniterm has no windows to script") }

    return windows
  }

  /// Validates the peer's ancestry and binds the connection to a session root when found. A
  /// connection that cannot be bound remains unbound, and its calls are refused.
  private func bindConnection(_ connection: ScriptConnection) {
    let peerIdentity = ProcessIdentity(
      pid: connection.peer.pid, started: connection.peerStartTime)

    guard peerIdentity.isRunning else { return }

    guard let root = ProcessAncestry.findRoot(for: peerIdentity, in: sessionRoots) else {
      return
    }

    guard let generation = sessionRoots.sessionGeneration(for: root) else {
      return
    }

    connection.bind(to: root, generation: generation)
    controllersChanged()
  }

  /// Checks the pane first, so a refused send writes nothing. A file the pane did not take is
  /// removed at once.
  ///
  /// The check and the send run with no suspension between them, so the pane cannot change in
  /// between. The pane's previous file is the pane's no more once it takes this one.
  private func send(
    _ content: Data, named name: String, to target: ScriptTarget, caller: ScriptCaller
  ) throws -> ScriptValue {
    let windows = try requireWindows()

    guard let sentContent else { throw ScriptCallError.refused("uniterm cannot hold content") }

    try ScriptSentContent.checkName(name)
    let pane = try windows.prepareSend(to: target, caller: caller)

    // At most 1 MiB, a known size, so ADR-08 lets this write run on the main actor.
    let file = try sentContent.write(content, named: name)
    let reply: ScriptValue

    do {
      reply = try windows.send(to: pane, file: file, caller: caller)
    } catch {
      sentContent.discard(file, size: content.count)

      throw error
    }

    let key = PaneKey(window: pane.window, pane: pane.pane)

    if let previous = held.updateValue(Held(file: file, size: content.count), forKey: key) {
      sentContent.discard(previous.file, size: previous.size)
    }

    return reply
  }

  /// Removes the file of each pane that has closed, and gives its bytes back. A pane that is open
  /// keeps its last file, since the pane may still read it.
  private func releaseFilesOfClosedPanes() {
    guard let windows, let sentContent else { return }

    for (key, file) in held
    where !windows.isOpen(ScriptPaneReference(window: key.window, pane: key.pane)) {
      sentContent.discard(file.file, size: file.size)
      held[key] = nil
    }
  }

  /// Runs a function and turns what it returns, or throws, into the call's reply.
  private func answer(_ body: () throws -> ScriptValue) -> ScriptResult {
    do {
      return Self.result(of: try body())
    } catch {
      return Self.failure(error)
    }
  }

  /// A reply the frame cannot hold becomes a failure the script sees. For an applet command,
  /// which has already run by then, the failure says so, so the script never takes the command
  /// for one that was refused.
  private static func result(of value: ScriptValue, commandRan: Bool = false) -> ScriptResult {
    let kind: ScriptFailureKind = commandRan ? .replyLost : .failed
    let lead = commandRan ? "the command ran, but its reply" : "the answer"

    do {
      let payload = try value.encoded()

      guard payload.count <= ScriptProtocol.maxReplyPayload else {
        return .failure(kind, "\(lead) is too large for one reply")
      }

      return .ok(payload)
    } catch {
      return .failure(kind, "\(lead) could not be sent: \(error)")
    }
  }

  private static func failure(_ error: any Error) -> ScriptResult {
    guard let error = error as? ScriptCallError else {
      return .failure(.failed, "the call failed: \(error)")
    }

    return .failure(error.kind, error.text)
  }

  private func producer(for connection: ScriptConnection) -> StatusProducer? {
    var session = sessions[connection.id, default: Session()]

    if session.producer == nil {
      session.producer = issueProducer(session.name)
      sessions[connection.id] = session
    }

    return session.producer
  }

  private static func level(_ level: ScriptStatusLevel) -> StatusLevel {
    switch level {
    case .info: return .info
    case .warning: return .warning
    case .error: return .error
    }
  }

  /// The script names its own label, so the label is cleaned like any text from outside.
  static func label(for name: String) -> String {
    let cleaned = StatusText.bounded(name, maximumBytes: maxLabelBytes)

    return cleaned.isEmpty ? "script" : cleaned
  }

  /// Records a terminal session root for authority checking. The identity comes from the
  /// terminal's report of the process it spawned, never from a caller.
  public func recordSessionRoot(
    _ identity: ProcessIdentity, sessionGeneration: UInt64, window: UInt64, pane: NodeID
  ) {
    sessionRoots.add(
      SessionRootRegistry.SessionRoot(identity: identity, sessionGeneration: sessionGeneration))

    let key = PaneKey(window: window, pane: pane.rawValue)

    paneRoots[key, default: []].removeAll { $0 == identity }
    paneRoots[key, default: []].append(identity)
  }

  /// Removes a terminal session root when its session closes or is replaced. Every grant to that
  /// session ends.
  public func removeSessionRoot(_ identity: ProcessIdentity, window: UInt64, pane: NodeID) {
    let acting = controllers(actingFrom: window, pane: pane).filter {
      findConnection($0)?.binding?.root == identity && grants[$0] == nil
    }

    sessionRoots.remove(identity)

    let key = PaneKey(window: window, pane: pane.rawValue)

    paneRoots[key]?.removeAll { $0 == identity }

    if paneRoots[key]?.isEmpty == true { paneRoots[key] = nil }

    endGrants { $0.root == identity }
    acting.forEach(authorityEnded)
  }

  /// Forgets every session root in a closed window, and ends every grant to one of its panes. The
  /// applets report their own sessions ending as the window closes. This also covers a session
  /// whose end was never reported.
  public func windowClosed(_ window: UInt64) {
    for (key, roots) in paneRoots where key.window == window {
      roots.forEach(sessionRoots.remove)
      paneRoots[key] = nil
    }

    endGrants { $0.window == window }
  }

  /// The session root a grant to the pane binds to, or nil when the pane runs no recorded session.
  /// A pane with several tabs runs several sessions, and the newest one that still runs is chosen.
  public func sessionRoot(window: UInt64, pane: NodeID) -> ProcessIdentity? {
    paneRoots[PaneKey(window: window, pane: pane.rawValue)]?.last(where: sessionRoots.contains)
  }

  /// Records the request of an unbound connection. A connection asks once, however many calls it
  /// makes. A peer that has exited cannot ask, so a socket it handed on never reaches the user.
  private func recordPendingRequest(for connection: ScriptConnection) {
    guard !pendingRequests.contains(where: { $0.id == connection.id }),
      pendingRequests.count < Self.maxPendingRequests,
      ProcessInspection.isRunning(pid: connection.peer.pid, started: connection.peerStartTime)
    else { return }

    pendingRequests.append(
      PendingRequest(
        id: connection.id, pid: connection.peer.pid,
        executablePath: ProcessInspection.executablePath(of: connection.peer.pid),
        name: sessions[connection.id]?.name ?? "script", timestamp: Date()))

    notifyPendingRequestsChanged()
  }

  /// The requests the user has not answered, oldest first.
  public func allPendingRequests() -> [PendingRequest] {
    pendingRequests
  }

  /// Grants a waiting connection the session of one pane. The pane's root is read and checked now,
  /// so a pane whose session has ended cannot be granted.
  public func grantAccess(connection id: UInt64, window: UInt64, pane: NodeID) -> GrantResult {
    guard pendingRequests.contains(where: { $0.id == id }) else {
      return .failed("This program has no request waiting.")
    }

    guard let connection = findConnection(id), !connection.isClosed,
      ProcessInspection.isRunning(pid: connection.peer.pid, started: connection.peerStartTime)
    else {
      forget(connection: id)

      return .connectionClosed
    }

    guard !connection.isBound else {
      pendingRequests.removeAll { $0.id == id }
      notifyPendingRequestsChanged()

      return .failed("This program already acts for a pane, so it cannot be granted another.")
    }

    guard let root = sessionRoot(window: window, pane: pane),
      let generation = sessionRoots.sessionGeneration(for: root)
    else {
      return .failed("The pane has no running session to grant.")
    }

    connection.bind(to: root, generation: generation)

    grants[id] = ExplicitGrant(
      connection: id, pid: connection.peer.pid,
      executablePath: pendingRequests.first { $0.id == id }?.executablePath, window: window,
      pane: pane, root: root, generation: generation, grantedAt: Date())

    pendingRequests.removeAll { $0.id == id }
    notifyPendingRequestsChanged()
    controllersChanged()

    return .granted
  }

  /// Denies a request. The connection's calls stay refused, and it is not asked about again.
  public func denyRequest(connection id: UInt64) {
    guard pendingRequests.contains(where: { $0.id == id }) else { return }

    pendingRequests.removeAll { $0.id == id }
    declined.insert(id)
    notifyPendingRequestsChanged()
  }

  /// Ends a grant. The connection's calls are refused again, and it is not asked about again.
  public func revokeGrant(connection id: UInt64) {
    guard grants[id] != nil else { return }

    endGrants { $0.connection == id }
    declined.insert(id)
  }

  /// The grants that still hold, oldest first. A grant whose program exited, or whose session
  /// closed, has ended and is dropped here.
  public func allGrants() -> [ExplicitGrant] {
    endGrants { grant in
      guard let connection = findConnection(grant.connection) else { return true }

      return !connection.validateBinding(registry: sessionRoots)
    }

    return grants.values.sorted { ($0.grantedAt, $0.connection) < ($1.grantedAt, $1.connection) }
  }

  /// Ends each grant that matches. Its connection loses its binding, so its calls are refused
  /// again, and a connection whose program still runs may ask again.
  private func endGrants(where ends: (ExplicitGrant) -> Bool) {
    let ended = grants.values.filter(ends)

    guard !ended.isEmpty else { return }

    for grant in ended {
      grants[grant.connection] = nil
      findConnection(grant.connection)?.unbind()
      authorityEnded(grant.connection)
    }

    notifyPendingRequestsChanged()
  }

  /// Drops a connection's request and grant once the connection has gone, or once it is bound to
  /// its own pane and has nothing left to ask.
  func forget(connection id: UInt64) {
    let hadRequest = pendingRequests.contains { $0.id == id }
    let hadGrant = grants.removeValue(forKey: id) != nil

    pendingRequests.removeAll { $0.id == id }

    guard hadRequest || hadGrant else { return }

    notifyPendingRequestsChanged()
  }

  private func findConnection(_ id: UInt64) -> ScriptConnection? {
    listener.findConnection(id)
  }

  private func notifyPendingRequestsChanged() {
    onPendingRequestsChanged?()
    onPendingRequestsActiveChanged?(!pendingRequests.isEmpty)
  }
}
