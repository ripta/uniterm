import Foundation
import Preferences
import ProcessInspection
import ScriptWire

/// What the user chooses for a script file that declares nothing. Each choice lasts one run, and
/// none of them can be remembered.
public enum UndeclaredReviewChoice: Sendable, Equatable, CaseIterable {
  /// The run does not start.
  case reject

  /// The run starts. Clipboard calls ask each time, and pane calls follow the pane rules.
  case askEachUse

  /// The run starts with the clipboard read and the clipboard write granted for its length. A
  /// host launch still asks each time.
  case allowEverything
}

/// One undeclared script file that waits for the user, shown once however many others wait.
public struct UndeclaredReview: Identifiable, Equatable, Sendable {
  public let id: UInt64

  /// The script's file name, as the command reported it. It proves nothing.
  public let name: String

  /// The capabilities the run asked for with `--allow`. Nothing declares them.
  public let capabilities: [String]

  public let connection: UInt64
  public let pid: pid_t

  public init(id: UInt64, name: String, capabilities: [String], connection: UInt64, pid: pid_t) {
    self.id = id
    self.name = name
    self.capabilities = capabilities
    self.connection = connection
    self.pid = pid
  }
}

/// An undeclared run the user admitted and that has not ended.
public struct UndeclaredRun: Identifiable, Equatable, Sendable {
  public var id: UInt64 { connection }

  public let connection: UInt64
  public let name: String
  public let pid: pid_t
  public let capabilities: [String]

  /// Never `reject`, since a rejected run does not start.
  public let choice: UndeclaredReviewChoice

  public init(
    connection: UInt64, name: String, pid: pid_t, capabilities: [String],
    choice: UndeclaredReviewChoice
  ) {
    self.connection = connection
    self.name = name
    self.pid = pid
    self.capabilities = capabilities
    self.choice = choice
  }
}

struct WaitingUndeclared {
  let connection: ScriptConnection
  let request: UndeclaredBegin
  let reviewID: UInt64
}

extension ScriptHost {
  /// The mode the user chose. Without a settings store there is no way to choose, so it is strict.
  var scriptFileMode: ScriptFileMode {
    settings?.value(of: .scriptFileMode) ?? .strict
  }

  /// The refusal strict mode gives. It says what to add, what cannot be declared, and where the
  /// setting is, since the user may have meant to run an undeclared file.
  static func strictModeText(for name: String, switched: Bool = false) -> String {
    let lead =
      switched
      ? "uniterm switched to strict mode while \(name) waited, so it will not run."
      : "uniterm is in strict mode, so it will not run \(name), which declares nothing."

    return lead
      + " Begin the file with a (declare-permissions ...) form. A script that needs ffi or "
      + "modules cannot declare them, and can run only undeclared in unsafe mode. To allow "
      + "that, choose Unsafe for \"Script files\" in Settings."
  }

  // MARK: Beginning

  /// What a connection began with, before the host knows what it is.
  enum Begin {
    case plain(String)
    case undeclared(UndeclaredBegin)

    var name: String {
      switch self {
      case .plain(let name): return name
      case .undeclared(let begin): return begin.name
      }
    }
  }

  /// Tells the bundled command from any other program that begins a session.
  ///
  /// The cheap check is a cached comparison with the command's file. A command replaced on disk
  /// under a running app fails it, and would be taken for a generic peer, which asks nothing. So a
  /// peer the cheap check does not take for the command gets the full check, off the main actor,
  /// before it is admitted as a generic one. Its calls wait for that decision. A native entry's
  /// connection is adopted at once as before, and so is any peer when no check can be made.
  func begin(_ connection: ScriptConnection, _ begin: Begin) {
    let kind = plainPeerKind(of: connection)

    guard kind != .bundledRun, let settings = controllerSettings, let token = connection.peer.token,
      nativeLaunches[connection.peer.pid] == nil
    else { return begun(connection, begin, as: kind) }

    heldRequests[connection.id] = []

    Task { @MainActor [weak self] in
      let refusal = await Task.detached { settings.helper.refusal(forPeer: token) }.value

      self?.begun(connection, begin, as: refusal == nil ? .bundledRun : .genericPeer, held: true)
    }
  }

  private func begun(
    _ connection: ScriptConnection, _ begin: Begin, as kind: SessionKind, held: Bool = false
  ) {
    let waiting = heldRequests.removeValue(forKey: connection.id) ?? []

    if !(held && connection.isClosed) {
      switch begin {
      case .plain(let name): plainBegun(connection, name: name, as: kind)
      case .undeclared(let request): undeclaredBegun(connection, request, as: kind)
      }
    }

    for event in waiting { handle(event) }
  }

  /// A plain begin from the bundled command is refused, since the command says whether its file
  /// declares anything. Any other program keeps the admission it has always had.
  private func plainBegun(_ connection: ScriptConnection, name: String, as kind: SessionKind) {
    if kind == .bundledRun {
      connection.close()
      onRefusal(.plainBeginFromCommand)

      return
    }

    sessions[connection.id, default: Session()].name = Self.label(for: name)
    sessions[connection.id, default: Session()].kind = kind
    watchPeer(of: connection)
    bindConnection(connection)
    adoptNativeRun(connection)
  }

  /// Opens the session of an undeclared file. A program that is not the command keeps the
  /// admission any program on the socket gets, which asks nothing at start.
  private func undeclaredBegun(
    _ connection: ScriptConnection, _ request: UndeclaredBegin, as kind: SessionKind
  ) {
    sessions[connection.id, default: Session()].name = Self.label(for: request.name)
    sessions[connection.id, default: Session()].kind = kind

    guard kind == .bundledRun else {
      watchPeer(of: connection)
      bindConnection(connection)
      adoptNativeRun(connection)
      connection.send(.undeclaredAdmitted)

      return
    }

    guard claimProcessSession(connection) else {
      refuseController(connection, Self.secondSessionText)
      onRefusal(.secondSession)

      return
    }

    watchPeer(of: connection)
    bindConnection(connection)

    let name = sessions[connection.id]?.name ?? "script"

    guard scriptFileMode == .unsafe else {
      return refuseController(connection, Self.strictModeText(for: name))
    }

    guard let settings = controllerSettings, let token = connection.peer.token else {
      return refuseController(connection, "uniterm cannot tell which program asked.")
    }

    controllerAdmissions.insert(connection.id)

    Task { @MainActor [weak self] in
      let refusal = await Task.detached { settings.helper.refusal(forPeer: token) }.value

      self?.undeclaredAuthenticated(connection, request, refusal: refusal)
    }
  }

  /// The full check of the command finished. The mode is read again, since the user may have
  /// switched while it ran.
  private func undeclaredAuthenticated(
    _ connection: ScriptConnection, _ request: UndeclaredBegin, refusal: String?
  ) {
    controllerAdmissions.remove(connection.id)

    if let refusal { return refuseController(connection, refusal) }

    guard admissionStillWanted(connection) else {
      return refuseController(connection, "The program that asked for the run is gone.")
    }

    let name = sessions[connection.id]?.name ?? "script"

    guard scriptFileMode == .unsafe else {
      return refuseController(connection, Self.strictModeText(for: name, switched: true))
    }

    lastReviewID += 1

    let review = UndeclaredReview(
      id: lastReviewID, name: name, capabilities: request.capabilities,
      connection: connection.id, pid: connection.peer.pid)

    undeclaredReviews.append(review)
    waitingUndeclared[connection.id] = WaitingUndeclared(
      connection: connection, request: request, reviewID: review.id)

    connection.send(
      .controllerReviewing(
        "\(name) declares nothing and waits for your approval. Choose Window > Pending Requests "
          + "in uniterm to review it."))
    pendingChanged()
  }

  // MARK: Answering

  /// Answers a review of an undeclared file. The mode is read again, so an answer that comes after
  /// a switch to strict refuses the run. Returns why nothing started, for the user.
  @discardableResult
  public func decideUndeclaredReview(_ id: UInt64, _ choice: UndeclaredReviewChoice) -> String? {
    guard let review = undeclaredReviews.first(where: { $0.id == id }),
      let waiting = waitingUndeclared.removeValue(forKey: review.connection)
    else { return "The review is no longer waiting." }

    undeclaredReviews.removeAll { $0.id == id }
    pendingChanged()

    let connection = waiting.connection

    guard choice != .reject else {
      refuseController(connection, "You rejected \(review.name).")

      return nil
    }

    guard scriptFileMode == .unsafe else {
      refuseController(connection, Self.strictModeText(for: review.name, switched: true))

      return "uniterm is in strict mode now, so \(review.name) was refused."
    }

    guard admissionStillWanted(connection) else {
      refuseController(connection, "The program that asked for the run is gone.")

      return nil
    }

    admitUndeclared(waiting, review: review, choice: choice)

    return nil
  }

  private func admitUndeclared(
    _ waiting: WaitingUndeclared, review: UndeclaredReview, choice: UndeclaredReviewChoice
  ) {
    let id = waiting.connection.id

    undeclaredRuns[id] = UndeclaredRun(
      connection: id, name: review.name, pid: review.pid, capabilities: review.capabilities,
      choice: choice)

    if choice == .allowEverything {
      clipboardGrants[id] = [.clipboardRead, .clipboardWrite]
    }

    waiting.connection.send(.undeclaredAdmitted)
    controllersChanged()
  }

  /// The undeclared runs that are live, oldest connection first.
  public func allUndeclaredRuns() -> [UndeclaredRun] {
    undeclaredRuns.values.filter { run in
      listener.findConnection(run.connection).map { !$0.isClosed } ?? false
    }.sorted { $0.connection < $1.connection }
  }

  /// Ends an undeclared run's authority. Its next call is refused, and an Allow Everything grant
  /// goes with it.
  public func revokeUndeclaredRun(connection id: UInt64) {
    guard undeclaredRuns[id] != nil else { return }

    revokeControllers([id])
  }

  // MARK: Ending

  /// Refuses every review that waits.
  func refuseWaitingUndeclared(_ text: (String) -> String) {
    let waiting = waitingUndeclared

    waitingUndeclared = [:]
    undeclaredReviews = []

    for entry in waiting.values {
      refuseController(entry.connection, text(sessions[entry.connection.id]?.name ?? "script"))
    }

    if !waiting.isEmpty { pendingChanged() }
  }

  /// The mode may have changed. A review that waits under strict mode is refused, and a live run is
  /// left to run. Switching to unsafe changes nothing for a run that has begun.
  func scriptFileModeMayHaveChanged() {
    guard scriptFileMode == .strict else { return }

    refuseWaitingUndeclared { Self.strictModeText(for: $0, switched: true) }
  }

  /// Forgets what a connection held, once it closed, was revoked, or lost its peer.
  func dropUndeclared(_ id: UInt64, refusal: String? = nil) {
    undeclaredRuns[id] = nil

    guard let waiting = waitingUndeclared.removeValue(forKey: id) else { return }

    undeclaredReviews.removeAll { $0.id == waiting.reviewID }
    pendingChanged()

    if let refusal, !waiting.connection.isClosed { refuseController(waiting.connection, refusal) }
  }
}
