import ControllerPackage
import Foundation
import PaneModel
import ProcessInspection
import QuestionForm
import ScriptWire

/// What a form's requester is, which decides how long its tab lives.
enum FormRequesterKind: Equatable, Sendable {
  /// A declared file run, a package run, or an undeclared run. Its tab goes when the run ends.
  case run

  /// A terminal session. Its tab stays after the program that asked ends, until the session's
  /// next form reuses it, the shell ends, or the user closes it.
  case session

  /// Any other connection, such as a REPL helper or a program the user granted a pane. Its tab
  /// goes when the connection ends.
  case connection

  /// Whether the requester's tab goes when the connection that opened the form ends.
  var closesTabWithConnection: Bool { self != .session }
}

/// One form a connection opened: the result slot ADR-11 asks for.
struct FormSlot {
  let handle: UInt64
  let connection: UInt64

  /// The pane the connection acted for when it opened the form. A wait delivers answers only to a
  /// caller that still acts for it.
  let caller: ScriptCaller

  let requester: FormRequester
  let kind: FormRequesterKind
  let spec: FormSpec

  /// Nil while the form is open.
  var outcome: FormOutcome?

  /// The request ID of the `wait-form` that waits for the result, if one does.
  var waiting: UInt32?

  var isOpen: Bool { outcome == nil }
}

/// The result slots of every connection's forms.
///
/// A connection holds at most `perConnection` slots, the cap the text viewer's handle table keeps.
/// A new slot drops the connection's oldest settled one when the connection is at the cap, and a
/// connection whose every slot is still open has no room.
///
/// A handle names one slot for the life of the host, so a handle that was freed never names
/// another form.
struct FormSlots {
  static let perConnection = 32

  private var slots: [UInt64: FormSlot] = [:]
  private var order: [UInt64] = []
  private var lastHandle: UInt64 = 0

  subscript(handle: UInt64) -> FormSlot? { slots[handle] }

  var isEmpty: Bool { slots.isEmpty }

  /// The next handle, which no slot has held. Nil when the handles ran out.
  mutating func nextHandle() -> UInt64? {
    guard lastHandle < ScriptProtocol.maxID else { return nil }

    lastHandle += 1

    return lastHandle
  }

  func slots(of connection: UInt64) -> [FormSlot] {
    order.compactMap { slots[$0] }.filter { $0.connection == connection }
  }

  /// True when the connection may open another form: it holds fewer than the cap, or one of its
  /// slots has settled.
  func hasRoom(for connection: UInt64) -> Bool {
    let held = slots(of: connection)

    return held.count < Self.perConnection || held.contains { !$0.isOpen }
  }

  /// Adds a slot, and drops the connection's oldest settled one when it is at the cap.
  mutating func insert(_ slot: FormSlot) {
    let held = slots(of: slot.connection)

    if held.count >= Self.perConnection, let oldest = held.first(where: { !$0.isOpen }) {
      remove(oldest.handle)
    }

    slots[slot.handle] = slot
    order.append(slot.handle)
  }

  mutating func update(_ handle: UInt64, _ change: (inout FormSlot) -> Void) {
    guard var slot = slots[handle] else { return }

    change(&slot)
    slots[handle] = slot
  }

  @discardableResult
  mutating func remove(_ handle: UInt64) -> FormSlot? {
    order.removeAll { $0 == handle }

    return slots.removeValue(forKey: handle)
  }

  /// The connections that hold a slot.
  var connections: Set<UInt64> { Set(slots.values.map(\.connection)) }

  mutating func removeAll() {
    slots = [:]
    order = []
  }
}

extension ScriptHost {
  static let formEndedText =
    "The form ended before it was answered, so nothing was submitted."

  static let formAuthorityText =
    "This program no longer acts for the pane it asked from, so the answers are not delivered."

  // MARK: Calls

  /// Runs `open-form`, `wait-form`, or `discard-form`. The call's power has passed. `wait-form`
  /// may answer later.
  func runFormCall(_ call: ScriptCall, id: UInt32, on connection: ScriptConnection) {
    if let refusal = authorize(connection) { return connection.reply(id: id, result: refusal) }

    switch call {
    case .openForm(let text):
      connection.reply(id: id, result: openForm(text, on: connection))

    case .waitForm(let handle):
      waitForm(handle, id: id, on: connection)

    case .discardForm(let handle):
      connection.reply(id: id, result: discardForm(handle, on: connection))

    default:
      connection.reply(id: id, result: .failure(.failed, "the call is not a form call"))
    }
  }

  private func openForm(_ text: String, on connection: ScriptConnection) -> ScriptResult {
    let spec: FormSpec

    do {
      spec = try FormSpecReader.decode(Data(text.utf8))
    } catch let error as FormSpecError {
      return .failure(.badArgument, "the form was refused. \(error)")
    } catch {
      return .failure(.badArgument, "the form was refused: \(error)")
    }

    guard let windows else { return .failure(.refused, "uniterm has no windows to show a form") }

    guard let caller = caller(for: connection) else {
      return .failure(.refused, "uniterm cannot tell which pane this program acts for.")
    }

    guard forms.hasRoom(for: connection.id) else {
      return .failure(
        .busy,
        "This program holds as many forms as it may. Discard one, then ask again.")
    }

    guard let handle = forms.nextHandle() else {
      return .failure(.failed, "uniterm has no more form handles to give.")
    }

    let (requester, kind) = formRequester(for: connection, caller: caller)

    do {
      try windows.openForm(spec, requester: requester, caller: caller) {
        [weak self] outcome in
        self?.formResolved(handle, outcome)
      }
    } catch {
      return Self.failure(error)
    }

    forms.insert(
      FormSlot(
        handle: handle, connection: connection.id, caller: caller, requester: requester,
        kind: kind, spec: spec))

    return Self.result(of: .integer(handle))
  }

  private func waitForm(_ handle: UInt64, id: UInt32, on connection: ScriptConnection) {
    guard let slot = forms[handle], slot.connection == connection.id else {
      return connection.reply(
        id: id, result: .failure(.notFound, "No form is open under that handle."))
    }

    guard slot.waiting == nil else {
      return connection.reply(
        id: id, result: .failure(.busy, "Another wait already waits on that form."))
    }

    guard slot.isOpen else {
      return connection.reply(id: id, result: formResult(slot, on: connection))
    }

    forms.update(handle) { $0.waiting = id }
  }

  private func discardForm(_ handle: UInt64, on connection: ScriptConnection) -> ScriptResult {
    guard let slot = forms[handle], slot.connection == connection.id else {
      return .failure(.notFound, "No form is open under that handle.")
    }

    forms.remove(handle)

    if let id = slot.waiting {
      connection.reply(id: id, result: .failure(.ended, Self.formEndedText))
    }

    if slot.isOpen {
      windows?.discardForm(requester: slot.requester.key, window: slot.caller.window)
    }

    return .ok(Data())
  }

  // MARK: Results

  /// The form ended. The answer is kept under the handle, and a wait that waits is answered.
  private func formResolved(_ handle: UInt64, _ outcome: FormOutcome) {
    guard let slot = forms[handle], slot.isOpen else { return }

    forms.update(handle) {
      $0.outcome = outcome
      $0.waiting = nil
    }

    guard let id = slot.waiting, let connection = listener.findConnection(slot.connection) else {
      return
    }

    var settled = slot

    settled.outcome = outcome

    connection.reply(id: id, result: formResult(settled, on: connection))
  }

  /// What a wait on a settled form answers. The caller's authority and binding are read again
  /// first, so a caller that lost either, or now acts for another pane, never sees the answers.
  private func formResult(_ slot: FormSlot, on connection: ScriptConnection) -> ScriptResult {
    guard formAuthorityHolds(slot, on: connection) else {
      return .failure(.ended, Self.formAuthorityText)
    }

    guard let outcome = slot.outcome,
      let value = outcome.scriptValue(form: slot.handle, spec: slot.spec)
    else { return .failure(.ended, Self.formEndedText) }

    return Self.result(of: value)
  }

  /// Whether the connection still acts for the pane it asked from. It runs the checks `authorize`
  /// runs, since no call from the program passes through that function while a wait waits. A
  /// program whose parent exited has moved to launchd, so its ancestry no longer leads to the
  /// session root it was bound to, and it gets no answers.
  func formAuthorityHolds(_ slot: FormSlot, on connection: ScriptConnection) -> Bool {
    guard !connection.isClosed, !isRevoked(connection.id), connection.peerGenerationHolds,
      connection.isBound, connection.validateBinding(registry: sessionRoots),
      caller(for: connection) == slot.caller
    else { return false }

    if grants[connection.id] == nil, let binding = connection.binding {
      let peer = ProcessIdentity(pid: connection.peer.pid, started: connection.peerStartTime)

      guard ProcessAncestry.findRoot(for: peer, in: sessionRoots) == binding.root else {
        return false
      }
    }

    if sessions[connection.id]?.kind == .controllerRun || sessions[connection.id]?.kind == .fileRun
    {
      return controllerRuns[connection.id] != nil
    }

    return true
  }

  // MARK: Endings

  /// A connection's authority ended: its run ended, its grant or binding went, the user revoked
  /// it, or it closed. Its forms end with nothing submitted, a wait that waits fails as ended, and
  /// every handle is freed. A requester that is a run or a connection loses its tab. A terminal
  /// session keeps a tab that shows an outcome, and shows the ended form in one that was open.
  func endForms(of connection: UInt64) {
    let held = forms.slots(of: connection)

    guard !held.isEmpty else { return }

    for slot in held { forms.remove(slot.handle) }

    let open = listener.findConnection(connection)

    for slot in held {
      if let id = slot.waiting { open?.reply(id: id, result: .failure(.ended, Self.formEndedText)) }

      if slot.kind.closesTabWithConnection {
        windows?.endForms(requester: slot.requester.key, window: slot.caller.window)
      } else if slot.isOpen {
        windows?.discardForm(requester: slot.requester.key, window: slot.caller.window)
      }
    }
  }

  /// A terminal session ended. Its requester's tab goes, a resolved one included.
  func endForms(ofSession root: ProcessIdentity, generation: UInt64?, window: UInt64) {
    guard let generation else { return }

    windows?.endForms(requester: Self.sessionKey(root, generation: generation), window: window)
  }

  /// The pending waits of a connection fail as ended, and its forms stay as they are. A REPL's
  /// stop request ends the wait that holds its VM, and the VM and its state go on.
  func failFormWaits(of connection: UInt64) {
    guard let open = listener.findConnection(connection) else { return }

    for slot in forms.slots(of: connection) {
      guard let id = slot.waiting else { continue }

      forms.update(slot.handle) { $0.waiting = nil }
      open.reply(id: id, result: .failure(.ended, Self.formEndedText))
    }
  }

  /// The REPL's stop request reached its helper. The wait that holds the helper's VM fails, so the
  /// VM unwinds the form it runs and keeps its state.
  func replStopRequested(on connection: UInt64) {
    failFormWaits(of: connection)
  }

  // MARK: Question-only sessions

  /// Starts the admission of the bundled command's question-only session. The command runs no
  /// script code, so strict mode and unsafe mode admit it alike, with no review. The app
  /// authenticates the command first, so no other program can take the session, and the
  /// one-session rule holds a process to one begin.
  func beginQuestionOnly(_ connection: ScriptConnection) {
    sessions[connection.id, default: Session()].name = "uniterm ask"
    sessions[connection.id, default: Session()].kind = .questionOnly

    guard claimIfBundledCommand(connection) else {
      refuseController(connection, Self.secondSessionText)
      onRefusal(.secondSession)

      return
    }

    guard let settings = controllerSettings, let token = connection.peer.token else {
      return refuseController(connection, "uniterm cannot tell which program asked.")
    }

    watchPeer(of: connection)
    bindConnection(connection)
    controllerAdmissions.insert(connection.id)

    Task { @MainActor [weak self] in
      let refusal = await Task.detached { settings.helper.refusal(forPeer: token) }.value

      self?.questionOnlyAuthenticated(connection, refusal: refusal)
    }
  }

  private func questionOnlyAuthenticated(_ connection: ScriptConnection, refusal: String?) {
    controllerAdmissions.remove(connection.id)

    if let refusal { return refuseController(connection, refusal) }

    guard admissionStillWanted(connection) else {
      return refuseController(connection, "The program that asked is gone.")
    }

    guard claimAfterFullCheck(connection) else {
      refuseController(connection, Self.secondSessionText)
      onRefusal(.secondSession)

      return
    }

    connection.send(.questionOnlyAdmitted)
  }

  // MARK: Requesters

  static func sessionKey(_ root: ProcessIdentity, generation: UInt64) -> String {
    "session:\(root.pid):\(root.started):\(generation)"
  }

  /// Who a connection's form names as its asker, from what the transport established. A script
  /// supplies none of it. The header never implies a verified file for a caller that has none,
  /// and never says "terminal session" for a caller that is not one.
  func formRequester(for connection: ScriptConnection, caller: ScriptCaller)
    -> (FormRequester, FormRequesterKind)
  {
    let id = connection.id
    let pane = "Pane \(caller.pane.rawValue)"

    if let run = controllerRuns[id] {
      let isFile = run.identity.artifact == .file
      let name = Self.label(for: run.identity.controllerID) + (isFile ? " (declared file)" : "")

      return (FormRequester(key: "run:\(id)", name: name), .run)
    }

    switch sessions[id]?.kind {
    case .bundledRun:
      let name = Self.label(for: sessions[id]?.name ?? "script") + " (unverified script)"

      return (FormRequester(key: "run:\(id)", name: name), .run)

    case .repl:
      return (FormRequester(key: "connection:\(id)", name: "REPL in \(pane)"), .connection)

    default:
      break
    }

    if grants[id] == nil, let binding = connection.binding {
      let key = Self.sessionKey(binding.root, generation: binding.generation)

      return (FormRequester(key: key, name: "Terminal session in \(pane)"), .session)
    }

    let program =
      ProcessInspection.executablePath(of: connection.peer.pid)
      .map { ($0 as NSString).lastPathComponent } ?? "program"

    return (
      FormRequester(
        key: "connection:\(id)",
        name: Self.label(for: "\(program) (PID \(connection.peer.pid)), granted \(pane)")),
      .connection
    )
  }
}
