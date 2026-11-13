import ControllerPackage
import ControllerTrust
import Foundation
import ScriptWire
import StatusKit

/// A controller run that the app verified and that waits for the user's review of its powers. Its
/// snapshot is kept until the run is admitted or refused.
struct WaitingAdmission {
  let connection: ScriptConnection
  let request: ControllerBegin
  let snapshot: ControllerSnapshot
  let entryHash: Data?
  let entryPath: String?
  let requested: Set<ControllerPermission>
}

/// One startup review: the powers a controller version asks for, shown to the user once. Runs of
/// the same version that ask for the same powers share it.
public struct ControllerReview: Identifiable, Equatable, Sendable {
  public let id: UInt64

  /// The descriptor's display name, which proves nothing.
  public let name: String

  public let identity: ControllerIdentity

  /// Every requested power, sorted.
  public let requested: [ControllerPermission]

  /// The powers a remembered policy for this controller does not cover yet, when one exists. The
  /// review shows them as what is new.
  public let added: [ControllerPermission]

  /// The policy the request goes beyond, when one exists.
  public let revises: ControllerSelector?

  /// False when the policy file cannot take a new policy, so only Allow once and Allow for this
  /// session are offered.
  public let canRemember: Bool

  /// Why nothing can be remembered, or why the policy file grants nothing.
  public let notice: String?

  /// The connections waiting, oldest first, with each one's process ID.
  public internal(set) var waiting: [(connection: UInt64, pid: pid_t)]

  public var isSigned: Bool { identity.keyFingerprint != nil }

  public init(
    id: UInt64, name: String, identity: ControllerIdentity, requested: [ControllerPermission],
    added: [ControllerPermission], revises: ControllerSelector?, canRemember: Bool,
    notice: String?, waiting: [(connection: UInt64, pid: pid_t)]
  ) {
    self.id = id
    self.name = name
    self.identity = identity
    self.requested = requested
    self.added = added
    self.revises = revises
    self.canRemember = canRemember
    self.notice = notice
    self.waiting = waiting
  }

  public static func == (lhs: ControllerReview, rhs: ControllerReview) -> Bool {
    lhs.id == rhs.id && lhs.name == rhs.name && lhs.identity == rhs.identity
      && lhs.requested == rhs.requested && lhs.added == rhs.added
      && lhs.waiting.map(\.connection) == rhs.waiting.map(\.connection)
  }
}

/// The user's answer to a startup review.
public enum ControllerReviewChoice: Sendable, Equatable {
  /// The oldest waiting run starts. Each later use of a power asks on its own.
  case allowOnce

  /// The oldest waiting run gets every requested power for its session.
  case allowForSession

  /// Every run of this exact verified version gets the requested powers, now and later.
  case trustVersion

  /// Every correctly signed version of this controller ID, under this key, gets them.
  case trustIdentity

  case deny
}

/// What came of a call's power check.
enum PowerCheck {
  case allowed
  case refused(ScriptResult)

  /// The power is declared and not standing, so the operation asks the user.
  case needsApproval(ControllerPermission)
}

// MARK: Startup review

extension ScriptHost {
  /// The key of a controller version's startup denial.
  static func startupKey(_ identity: ControllerIdentity) -> PermissionRequests.Key {
    PermissionRequests.Key(
      requester: .controllerVersion(
        controllerID: identity.controllerID, version: identity.version),
      power: "startup")
  }

  /// Puts a verified run before the user. A review of the same version and powers that already
  /// waits takes the run too, so a run started again joins the first question.
  func queueReview(_ waiting: WaitingAdmission, trust: TrustLookup) {
    let identity = waiting.snapshot.controller.identity
    let requested = waiting.requested.sorted()
    let peer = (waiting.connection.id, waiting.connection.peer.pid)

    waitingAdmissions[waiting.connection.id] = waiting

    if let index = controllerReviews.firstIndex(where: {
      $0.identity == identity && $0.requested == requested
    }) {
      controllerReviews[index].waiting.append(peer)
    } else {
      lastReviewID += 1
      controllerReviews.append(
        ControllerReview(
          id: lastReviewID, name: waiting.snapshot.controller.descriptor.name,
          identity: identity, requested: requested,
          added: trust.nearest.map { $0.uncovered(waiting.requested) } ?? requested,
          revises: trust.nearest?.selector,
          canRemember: trust.writable && controllerSettings?.trust != nil,
          notice: trust.notice, waiting: [peer]))
    }

    waiting.connection.send(
      .controllerReviewing(
        "\(identity.controllerID) waits for your approval. Choose Window > Pending Requests in "
          + "uniterm to review what it asks for."))
    pendingChanged()
  }

  /// Answers a startup review. Allow once and Allow for this session admit the oldest waiting
  /// run alone. A trust choice saves the policy first, then admits every run the review holds,
  /// since the new policy covers each of them. Returns why nothing happened, for the user.
  @discardableResult
  public func decideReview(_ id: UInt64, _ choice: ControllerReviewChoice) async -> String? {
    guard let review = controllerReviews.first(where: { $0.id == id }) else {
      return "The review is no longer waiting."
    }

    switch choice {
    case .allowOnce, .allowForSession:
      guard let first = review.waiting.first else { return nil }

      removeFromReviews([first.connection])

      guard let waiting = waitingAdmissions.removeValue(forKey: first.connection) else {
        return nil
      }

      let standing =
        choice == .allowOnce
        ? waiting.requested.filter { $0.capabilityName != nil } : waiting.requested

      admitRun(waiting, approval: choice == .allowOnce ? .once : .session, standing: standing)

    case .trustVersion, .trustIdentity:
      let selector: ControllerSelector

      if choice == .trustIdentity {
        guard let fingerprint = review.identity.keyFingerprint else {
          return "This controller is not signed, so only its version can be trusted."
        }

        selector = .identity(
          controllerID: review.identity.controllerID, keyFingerprint: fingerprint)
      } else {
        selector = .version(
          controllerID: review.identity.controllerID, version: review.identity.version)
      }

      guard review.canRemember, let store = controllerSettings?.trust else {
        return review.notice ?? "uniterm cannot save trust now."
      }

      let policy = ControllerPolicy(
        selector: selector, name: review.name, scopes: Set(review.requested),
        approved: ISO8601DateFormatter().string(from: Date()))

      let revision = trustRemovals
      let saved = await Task.detached { () -> String? in
        do {
          try store.update { policies in
            var result = policies.filter { $0.selector != selector }
            let earlier = policies.first { $0.selector == selector }

            result.append(
              ControllerPolicy(
                selector: selector, name: policy.name,
                scopes: PermissionContainment.merged(earlier?.scopes ?? [], with: policy.scopes),
                approved: policy.approved))

            return result
          }

          return nil
        } catch {
          return "uniterm could not save the trust: \(error)"
        }
      }.value

      if let saved { return saved }

      // The review may have changed while the policy was saved. Only runs still in it start.
      guard let current = controllerReviews.first(where: { $0.id == id }) else { return nil }

      let connections = current.waiting.map(\.connection)

      removeFromReviews(connections)
      trustChanged()

      // A removal that overlapped the save may have taken the policy away again. The user still
      // approved these runs here, so they start for this session, under no policy.
      let approval: ControllerApproval =
        trustRemoved(since: revision) ? .session : .remembered(selector)

      for connection in connections {
        guard let waiting = waitingAdmissions.removeValue(forKey: connection) else { continue }

        admitRun(waiting, approval: approval, standing: waiting.requested)
      }

    case .deny:
      let connections = review.waiting.map(\.connection)

      removeFromReviews(connections)
      permissionRequests.recordDenial(
        Self.startupKey(review.identity),
        subject: "\(review.name) (\(review.identity.controllerID))",
        title: "Start this version")

      for connection in connections {
        guard let waiting = waitingAdmissions.removeValue(forKey: connection) else { continue }

        waiting.snapshot.remove()
        refuseController(
          waiting.connection,
          "You denied this controller. To be asked again, choose Ask Again in Window > Pending "
            + "Requests, then run it again.")
      }
    }

    return nil
  }

  /// Takes connections out of every review, and drops reviews left with none.
  private func removeFromReviews(_ connections: [UInt64]) {
    for index in controllerReviews.indices {
      controllerReviews[index].waiting.removeAll { connections.contains($0.connection) }
    }

    controllerReviews.removeAll { $0.waiting.isEmpty }
    pendingChanged()
  }

  /// Ends a run that waits for review: its connection closed, its peer changed, or the user
  /// revoked it. Its snapshot goes.
  func dropWaitingAdmission(_ id: UInt64, refusal: String? = nil) {
    guard let waiting = waitingAdmissions.removeValue(forKey: id) else { return }

    removeFromReviews([id])
    waiting.snapshot.remove()

    if let refusal, !waiting.connection.isClosed { refuseController(waiting.connection, refusal) }
  }
}

// MARK: Remembered trust

extension ScriptHost {
  /// The policy file as it is now. It is read off the main actor.
  public func rememberedTrust() async -> ControllerTrustState {
    guard let store = controllerSettings?.trust else {
      return ControllerTrustState(
        policies: [], writable: false, notice: "This uniterm remembers no controller trust.")
    }

    return await Task.detached { store.read() }.value
  }

  /// Removes a remembered policy, then ends the authority of every live run it admitted, with the
  /// work those runs have waiting. Returns why it failed, for the user. A policy that cannot be
  /// removed leaves the runs as they were, so the window never shows a revoke that did not happen.
  @discardableResult
  public func forgetPolicy(_ selector: ControllerSelector) async -> String? {
    guard let store = controllerSettings?.trust else { return "No trust is remembered." }

    trustRemovals += 1
    trustRemovalsUnderWay += 1

    defer {
      trustRemovalsUnderWay -= 1
      trustRemovals += 1
    }

    let failure = await Task.detached { () -> String? in
      do {
        try store.update { $0.filter { $0.selector != selector } }

        return nil
      } catch {
        return "uniterm could not remove the policy: \(error)"
      }
    }.value

    if let failure { return failure }

    let admitted = controllerRuns.values.filter { $0.approval == .remembered(selector) }

    revokeControllers(Set(admitted.map(\.connection)))

    for (pid, launch) in nativeLaunches where launch.approval == .remembered(selector) {
      nativeLaunches[pid] = nil
      endNativeLaunch(launch, pid: pid)
    }

    trustChanged()

    return nil
  }

  /// True when a live controller run may have uniterm start this program in a pane of a group it
  /// owns, without asking. The run's own standing approval must hold a host launch that covers the
  /// executable, the directory, and every environment key. A run allowed once has none, so its
  /// launches ask one at a time.
  ///
  /// Both folders are compared with every link resolved, so a link inside the approved folder
  /// that leads out of it is not covered. A folder that does not exist is not covered. The links
  /// are resolved off the main actor, and the run is checked again once they are.
  public func coversLaunch(
    connection id: UInt64, executable: String, directory: String, environmentKeys: [String]
  ) async -> Bool {
    guard let run = liveRun(id) else { return false }

    let folders = run.standing.compactMap { permission -> String? in
      guard case .hostLaunch(let approved) = permission.kind else { return nil }

      return approved.directory
    }

    let resolved = await Task.detached { () -> (wanted: String?, approved: [String: String]) in
      var approved: [String: String] = [:]

      for folder in folders { approved[folder] = HostLaunchScope.resolved(folder) }

      return (HostLaunchScope.resolved(directory), approved)
    }.value

    // The run may have ended, or its standing changed, while the links were resolved.
    guard let current = liveRun(id), let folder = resolved.wanted,
      let scope = try? HostLaunchScope(
        executable: executable, directory: folder, environmentKeys: environmentKeys)
    else { return false }

    let standing = Set(
      current.standing.compactMap { permission -> ControllerPermission? in
        guard case .hostLaunch(let approved) = permission.kind else { return permission }

        guard let folder = resolved.approved[approved.directory],
          let scope = try? HostLaunchScope(
            executable: approved.executable, directory: folder,
            environmentKeys: approved.environmentKeys)
        else { return nil }

        return ControllerPermission(.hostLaunch(scope), version: permission.version)
      })

    return PermissionContainment.uncovered([.hostLaunch(scope)], by: standing).isEmpty
  }

  /// The run a connection is bound to, while its authority holds.
  private func liveRun(_ id: UInt64) -> ControllerRun? {
    guard let run = controllerRuns[id], !isRevoked(id),
      let connection = listener.findConnection(id), !connection.isClosed,
      connection.peerGenerationHolds, run.generation == connection.peer.token?.pidVersion
    else { return nil }

    return run
  }

  func trustChanged() {
    changes.notify()
  }

  func pendingChanged() {
    onPendingRequestsChanged?()
    onPendingRequestsActiveChanged?(hasPendingWork)
    changes.notify()
  }

  /// True while anything waits for the user: a program's pane request, a startup review, or a
  /// permission question.
  public var hasPendingWork: Bool {
    !allPendingRequests().isEmpty || !controllerReviews.isEmpty || permissionRequests.isWaiting
  }
}

// MARK: Powers at the call boundary

extension ScriptHost {
  /// The power a call uses, or nil for a call that needs none, such as posting status.
  static func power(for call: ScriptCall) -> ControllerPermission? {
    switch call {
    case .postStatus: return nil
    case .readClipboard: return .clipboardRead
    case .writeClipboard: return .clipboardWrite
    case .listWindows, .listPanes, .openPane, .openTab, .send, .sendCommand, .requestLayout:
      return .paneControl
    }
  }

  /// Checks a call's power against the live grant. `once` is the one power an Allow once answer
  /// granted for this operation alone.
  ///
  /// A controller run may use only what it declared, and without asking only what stands. An
  /// ordinary script's pane calls follow the pane rules alone, and its clipboard calls need the
  /// user's answer each time, unless the user allowed them for the connection.
  func checkPower(
    _ call: ScriptCall, on connection: ScriptConnection, once: ControllerPermission? = nil
  ) -> PowerCheck {
    if controllerAdmissions.contains(connection.id) || waitingAdmissions[connection.id] != nil {
      return .refused(.failure(.refused, "uniterm has not admitted this controller yet."))
    }

    let power = Self.power(for: call)

    guard let run = controllerRuns[connection.id] else {
      guard let power, power != .paneControl else { return .allowed }

      if power == once || clipboardGrants[connection.id]?.contains(power) == true {
        return .allowed
      }

      return .needsApproval(power)
    }

    guard run.generation == connection.peer.token?.pidVersion, connection.peerGenerationHolds
    else {
      return .refused(.failure(.refused, "This controller run has ended."))
    }

    guard let power else { return .allowed }

    guard run.scopes.contains(power) else {
      return .refused(
        .failure(
          .refused,
          "This controller did not declare \(power.kindName) in its controller.json, so it "
            + "cannot \(power == .paneControl ? "act on panes" : Self.verb(for: power))."))
    }

    if power == once || run.standing.contains(power) { return .allowed }

    return .needsApproval(power)
  }

  private static func verb(for power: ControllerPermission) -> String {
    power == .clipboardRead ? "read the clipboard" : "replace the clipboard"
  }

  /// Puts an operation that needs the user's answer in the Pending Requests panel. The call is
  /// answered when the user answers: Allow once runs this call alone, Allow for the session also
  /// keeps the power for the run or the connection, and Deny refuses it.
  func askForOperation(
    _ call: ScriptCall, id: UInt32, on connection: ScriptConnection, power: ControllerPermission
  ) {
    let key = PermissionRequests.Key(requester: .connection(connection.id), power: power.kindName)
    let run = controllerRuns[connection.id]
    let isRun = run != nil
    let subject = controllerName(connection.id) ?? "a script"

    var detail = "\(subject) asks to \(power.displayText.lowercased())."

    if case .writeClipboard(let text) = call {
      detail +=
        " It would write: \u{201C}\(StatusText.bounded(text, maximumBytes: 160))\u{201D}"
    }

    detail +=
      isRun
      ? " Allow for This Run lets this run do it again without asking, until it ends."
      : " Allow for This Connection lets this program do it again without asking, until it "
        + "disconnects."

    let outcome = permissionRequests.ask(
      key, deniedAs: denialKey(for: connection, run: run, power: power), subject: subject,
      title: power.displayText, detail: detail,
      sessionTitle: isRun ? "Allow for This Run" : "Allow for This Connection"
    ) { [weak self, weak connection] answer in
      guard let self, let connection else { return }

      switch answer {
      case .deny:
        connection.reply(id: id, result: .failure(.refused, "You denied this request."))

      case .withdrawn:
        connection.reply(
          id: id,
          result: .failure(
            .refused,
            "The request ended before you answered it, since this program lost the authority it "
              + "asked under."))

      case .allowOnce:
        dispatch(call, id: id, on: connection, once: power)

      case .allowForSession:
        grantStanding(power, to: connection.id)
        dispatch(call, id: id, on: connection, once: nil)
      }
    }

    switch outcome {
    case .waiting:
      pendingChanged()

    case .denied:
      connection.reply(
        id: id,
        result: .failure(
          .refused,
          "You denied this earlier. To be asked again, choose Ask Again in Window > Pending "
            + "Requests."))

    case .busy:
      connection.reply(
        id: id,
        result: .failure(
          .busy, "Too many of this program's requests wait for the user. Try again later."))
    }
  }

  /// What a denial of a connection's request is kept under, so that the program cannot ask
  /// again by reconnecting. A controller run's denial covers its verified version, as a denied
  /// startup review does. An ordinary script names nothing a reconnect could not, so its denial
  /// covers the scripts acting for its pane. Nil keeps the denial under the connection.
  private func denialKey(
    for connection: ScriptConnection, run: ControllerRun?, power: ControllerPermission
  ) -> PermissionRequests.Key? {
    if let run {
      return PermissionRequests.Key(
        requester: .controllerVersion(
          controllerID: run.identity.controllerID, version: run.identity.version),
        power: power.kindName)
    }

    guard let caller = caller(for: connection) else { return nil }

    return PermissionRequests.Key(
      requester: .paneScripts(window: caller.window, pane: caller.pane.rawValue),
      power: power.kindName)
  }

  /// Keeps a power the user allowed for the session.
  private func grantStanding(_ power: ControllerPermission, to id: UInt64) {
    if controllerRuns[id] != nil {
      controllerRuns[id]?.standing.insert(power)
      controllersChanged()
    } else if !(listener.findConnection(id)?.isClosed ?? true) {
      clipboardGrants[id, default: []].insert(power)
    }
  }

  /// Reads or writes the clipboard. This is the access boundary: the live grant is checked here,
  /// with nothing suspended before the clipboard is touched. A read waits off the main actor for
  /// the text, so the grant is checked again before any text goes to the program.
  func performClipboard(
    _ call: ScriptCall, on connection: ScriptConnection, once: ControllerPermission?
  ) async -> ScriptResult {
    if let refusal = clipboardRefusal(call, on: connection, once: once) { return refusal }

    guard let clipboard else {
      return .failure(.refused, "uniterm has no clipboard to offer.")
    }

    switch call {
    case .readClipboard:
      let text = await clipboard.readText()

      if let refusal = clipboardRefusal(call, on: connection, once: once) { return refusal }

      guard let text else { return .ok(Data([0])) }

      let bytes = Data(text.utf8)

      guard bytes.count <= ScriptProtocol.maxClipboardBytes else {
        return .failure(
          .failed,
          "The clipboard holds \(bytes.count) bytes of text, more than the "
            + "\(ScriptProtocol.maxClipboardBytes) a script may read.")
      }

      return .ok(Data([1]) + bytes)

    case .writeClipboard(let text):
      clipboard.writeText(text)

      return .ok(Data())

    default:
      return .failure(.failed, "the call does not use the clipboard")
    }
  }

  /// Why a clipboard call may not touch the clipboard now, or nil when it may.
  private func clipboardRefusal(
    _ call: ScriptCall, on connection: ScriptConnection, once: ControllerPermission?
  ) -> ScriptResult? {
    if connection.isClosed { return .failure(.refused, "The program has gone.") }

    if let refusal = authorize(connection) { return refusal }

    switch checkPower(call, on: connection, once: once) {
    case .allowed: return nil
    case .refused(let result): return result
    case .needsApproval: return .failure(.refused, "The permission for this request has ended.")
    }
  }
}
