import ControllerPackage
import ControllerTestSupport
import Darwin
import FileRouting
import Foundation
import PaneModel
import Preferences
import ProcessInspection
import ScriptTestSupport
import ScriptWire
import XCTest

@testable import ScriptHost

/// A helper whose full check of a peer waits for the test, so a call can arrive while the host
/// still authenticates the command.
private struct GatedAcceptingHelper: ControllerHelperIdentity {
  let gate: DispatchSemaphore

  func refusal(forPeer token: AuditToken) -> String? {
    gate.wait()

    return nil
  }

  func isRunningCommand(_ token: AuditToken) -> Bool { true }
}

/// The question-only session that `uniterm ask` opens, and the form calls of an undeclared run.
///
/// Raw peers play the bundled command against a host that takes every peer for it, with a fake
/// window layer. They prove what the host admits and refuses. They cannot prove that the real
/// command sends this begin, which the UI tests and M4's script fixtures prove.
@MainActor
final class QuestionOnlySessionTests: XCTestCase {
  private var directory: URL!
  private var work: URL!
  private var host: ScriptHost!
  private var settings: TestScriptSettings!
  private var windows: FakeWindowAPI!
  private var refusals: [ScriptRefusal] = []
  private var peers: [FramedSocket] = []

  override func setUp() async throws {
    directory = try ScriptFixtures.makeSocketDirectory()
    work = try ControllerFixtures.temporaryFolder()
    settings = TestScriptSettings()
    windows = FakeWindowAPI()
  }

  override func tearDown() async throws {
    for peer in peers { peer.shutdownAndClose() }

    host?.stop()
    settings.remove()
    try? FileManager.default.removeItem(at: directory)
    ControllerSnapshot.removeStale(in: work.appendingPathComponent("runs"))
    try? FileManager.default.removeItem(at: work)
  }

  private func startHost(helper: any ControllerHelperIdentity) throws {
    host = try ScriptFixtures.makeFileHost(
      directory: directory, work: work, helper: helper,
      onRefusal: { [weak self] in self?.refusals.append($0) }, settings: settings.store,
      windows: windows)
  }

  private func connect() async throws -> FramedSocket {
    let peer = try await ScriptFixtures.openPeer(host: host)

    peers.append(peer)

    return peer
  }

  private func read(_ peer: FramedSocket) async throws -> ScriptAppMessage {
    try await ScriptFixtures.readMessage(peer)
  }

  /// A raw peer whose question-only session the host admitted.
  private func admittedPeer() async throws -> FramedSocket {
    let peer = try await connect()

    try peer.send(ScriptHelperMessage.questionBegin.frame())

    guard case .questionOnlyAdmitted = try await read(peer) else {
      throw Unexpected(text: "the question-only session was not admitted")
    }

    return peer
  }

  private func call(_ peer: FramedSocket, _ call: ScriptCall, id: UInt32 = 1) async throws
    -> ScriptResult
  {
    try peer.send(ScriptHelperMessage.request(id: id, call: call).frame())

    guard case .reply(let answered, let result) = try await read(peer), answered == id else {
      throw Unexpected(text: "the call was not answered")
    }

    return result
  }

  private static let spec = #"{"items": [{"id": "ok", "text": "Sure?", "type": "boolean"}]}"#

  // MARK: Admission

  private func assertAdmittedWithNoReview(in mode: ScriptFileMode) async throws {
    settings.set(mode)
    try startHost(helper: AcceptingHelper())

    let peer = try await admittedPeer()

    XCTAssertTrue(host.undeclaredReviews.isEmpty, "\(mode)")
    XCTAssertFalse(host.hasPendingWork, "\(mode)")

    let result = try await call(peer, .openForm(spec: Self.spec))

    guard case .ok = result else { return XCTFail("a form was refused in \(mode): \(result)") }
  }

  /// Catches strict mode refusing `uniterm ask`, which the undeclared begin does, and a review
  /// that the bare caller's no-prompt rule rules out. The session is admitted at once, and its
  /// form opens.
  func testTheSessionIsAdmittedInStrictModeWithNoReview() async throws {
    try await assertAdmittedWithNoReview(in: .strict)
  }

  /// Catches unsafe mode putting a review before each `uniterm ask`, as it does for an undeclared
  /// file.
  func testTheSessionIsAdmittedInUnsafeModeWithNoReview() async throws {
    try await assertAdmittedWithNoReview(in: .unsafe)
  }

  /// Catches a question-only session whose header claims a verified script. The command runs no
  /// script code, so it is a bare terminal-session caller, named by its pane.
  func testTheHeaderNamesATerminalSessionInThePane() async throws {
    try startHost(helper: AcceptingHelper())

    let peer = try await admittedPeer()
    let result = try await call(peer, .openForm(spec: Self.spec))

    guard case .ok = result else { return XCTFail("\(result)") }

    let asked = try XCTUnwrap(windows.askedForms.first)

    XCTAssertEqual(asked.requester.name, "Terminal session in Pane 1")
    XCTAssertTrue(asked.requester.key.hasPrefix("session:"), asked.requester.key)
  }

  /// Catches a generic peer taking the session, which would let any program ask forms as the
  /// command. The full check of the command refuses it, and nothing opens.
  func testAGenericPeerCannotBeginAQuestionOnlySession() async throws {
    try startHost(helper: RejectingHelper())

    let peer = try await connect()

    try peer.send(ScriptHelperMessage.questionBegin.frame())

    guard case .controllerRefused(let text) = try await read(peer) else {
      return XCTFail("a generic peer was admitted")
    }

    XCTAssertTrue(text.contains("not the command"), text)
    XCTAssertTrue(windows.askedForms.isEmpty)
  }

  /// Catches a second begin from one process, such as a declared run that opened another
  /// connection. UTERM-021's one-run rule refuses it, whichever session came first.
  func testASecondSessionFromTheSameProcessIsRefused() async throws {
    try startHost(helper: AcceptingHelper())

    _ = try await admittedPeer()

    let second = try await connect()

    try second.send(ScriptHelperMessage.questionBegin.frame())

    guard case .controllerRefused(let text) = try await read(second) else {
      return XCTFail("a second question-only session was admitted")
    }

    XCTAssertEqual(text, ScriptHost.secondSessionText)
    XCTAssertEqual(refusals, [.secondSession])
  }

  /// Catches a run of another kind, that has begun, leaving room for a question-only begin from
  /// the same process.
  func testAQuestionOnlyBeginAfterARunFromTheSameProcessIsRefused() async throws {
    settings.set(.unsafe)
    try startHost(helper: AcceptingHelper())

    let first = try await connect()

    try first.send(ScriptHelperMessage.undeclaredBegin(UndeclaredBegin(name: "run.janet")).frame())

    guard case .controllerReviewing = try await read(first) else {
      return XCTFail("the run was not put before the user")
    }

    let second = try await connect()

    try second.send(ScriptHelperMessage.questionBegin.frame())

    guard case .controllerRefused(let text) = try await read(second) else {
      return XCTFail("a question-only session was admitted beside a run")
    }

    XCTAssertEqual(text, ScriptHost.secondSessionText)
  }

  /// Catches a call served before the command is authenticated. The call waits in no queue: it is
  /// refused, and nothing opens, while the full check is still running.
  func testACallBeforeTheAdmissionIsRefused() async throws {
    let gate = DispatchSemaphore(value: 0)

    try startHost(helper: GatedAcceptingHelper(gate: gate))

    let peer = try await connect()

    try peer.send(ScriptHelperMessage.questionBegin.frame())
    expect(await waitUntil { !self.host.controllerAdmissions.isEmpty })

    let result = try await call(peer, .openForm(spec: Self.spec))

    gate.signal()

    guard case .failure(.refused, let text) = result else {
      return XCTFail("a call was served before the admission: \(result)")
    }

    XCTAssertTrue(text.contains("not admitted"), text)
    XCTAssertTrue(windows.askedForms.isEmpty)
  }

  // MARK: Allowed calls

  /// Catches a question-only session that can drive the app. Any call but a form call ends the
  /// connection as a protocol violation, since the command never sends one. The form calls work.
  func testAnyCallButAFormCallEndsTheSession() async throws {
    try startHost(helper: AcceptingHelper())

    let peer = try await admittedPeer()
    let handle = try await call(peer, .openForm(spec: Self.spec))

    guard case .ok = handle else { return XCTFail("\(handle)") }

    for forbidden: ScriptCall in [
      .postStatus(level: .info, text: "x"), .listWindows, .readClipboard,
      .requestLayout(pane: .nearest(kind: "terminal"), layout: "{}"),
    ] {
      let intruder = try await admittedPeerFromAnotherHostSession()

      try intruder.send(ScriptHelperMessage.request(id: 2, call: forbidden).frame())

      do {
        _ = try await read(intruder)
        XCTFail("\(forbidden) was answered on a question-only session")
      } catch {
        XCTAssertEqual(error as? WireError, .closed, "\(forbidden)")
      }
    }

    expect(await waitUntil { self.refusals.contains(where: \.isProtocolViolation) })
  }

  /// A question-only session that the host admitted before the one under test, on a process of
  /// its own. A second session from the test process would be refused, so the host's claim table
  /// forgets the first.
  private func admittedPeerFromAnotherHostSession() async throws -> FramedSocket {
    host.processSessions = [:]

    return try await admittedPeer()
  }

  // MARK: Undeclared runs

  /// Catches a header that implies a verified file for an undeclared run. The unsafe run is named
  /// by the file name it announced, as an unverified script, and its form is keyed by the run.
  func testAnUnsafeUndeclaredRunsHeaderNamesItAsUnverified() async throws {
    settings.set(.unsafe)
    try startHost(helper: AcceptingHelper())

    let peer = try await connect()

    try peer.send(ScriptHelperMessage.undeclaredBegin(UndeclaredBegin(name: "tidy.janet")).frame())

    guard case .controllerReviewing = try await read(peer) else {
      return XCTFail("the run was not put before the user")
    }

    let review = try XCTUnwrap(host.undeclaredReviews.first)

    XCTAssertNil(host.decideUndeclaredReview(review.id, .askEachUse))

    guard case .undeclaredAdmitted = try await read(peer) else {
      return XCTFail("the run was not admitted")
    }

    let result = try await call(peer, .openForm(spec: Self.spec))

    guard case .ok = result else { return XCTFail("\(result)") }

    let asked = try XCTUnwrap(windows.askedForms.first)

    XCTAssertEqual(asked.requester.name, "tidy.janet (unverified script)")
    XCTAssertTrue(asked.requester.key.hasPrefix("run:"), asked.requester.key)
  }
}

extension ScriptRefusal {
  fileprivate var isProtocolViolation: Bool {
    if case .protocolViolation = self { return true }

    return false
  }
}

private struct Unexpected: Error {
  let text: String
}
