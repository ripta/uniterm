import AppKit
import AppletKit
import AppletTestSupport
import XCTest

@testable import TerminalApplet
@testable import TerminalSurface

/// How a terminal applies its pane's control to its sessions, and how it asks about a controlled
/// session's clipboard use. Fake sessions record each policy they get. The real backend's
/// callbacks are proved in `TerminalSessionIntegrationTests`.
@MainActor
final class TerminalControlTests: XCTestCase {
  private var retained: [TerminalApplet] = []

  private let controlled = PaneControl(access: .remoteControlled, driver: .none, generation: 5)

  private func makeApplet() -> (TerminalApplet, FakeEngine, RecordingHost) {
    let engine = FakeEngine()
    let host = RecordingHost()
    let applet = TerminalApplet(engine: engine, directoryExists: { _ in true })
    applet.host = host
    applet.start(origin: .user)
    retained.append(applet)
    return (applet, engine, host)
  }

  private func settle(_ condition: () -> Bool) async {
    for _ in 0..<200 where !condition() {
      try? await Task.sleep(for: .milliseconds(10))
    }
  }

  /// Catches a background tab that keeps the interactive policy after its pane becomes
  /// controlled. Every tab's session has the new policy when the call returns.
  func testEveryTabTakesTheControlledPolicyBeforeTheChangeReturns() {
    let (applet, engine, _) = makeApplet()

    applet.openTab()
    applet.selectTab(at: 0)
    applet.controlDidChange(controlled)

    let expected = TerminalClipboardPolicy(controlled: true, generation: 5)

    XCTAssertEqual(engine.sessions.count, 2)
    XCTAssertEqual(engine.sessions.map(\.clipboardPolicy), [expected, expected])
  }

  /// Catches a tab opened or reopened in a controlled pane that starts with the interactive policy
  /// and only later gets the controlled one, which would let its first output write the clipboard.
  /// Each session is made with the controlled policy.
  func testTabsOpenedOrReopenedLaterAreMadeWithTheControlledPolicy() async {
    let (applet, engine, host) = makeApplet()
    let expected = TerminalClipboardPolicy(controlled: true, generation: 5)

    applet.controlDidChange(controlled)
    applet.openTab()

    XCTAssertEqual(engine.sessions.last?.clipboardPolicies, [expected])

    let result = await applet.closeCurrentTab()

    XCTAssertEqual(result, .closed)

    let stamp = try? XCTUnwrap(applet.closedTabStamps.first)

    XCTAssertEqual(applet.reopenTab(stamp: stamp ?? 0), .reopened(title: "Terminal"))
    XCTAssertEqual(engine.sessions.last?.clipboardPolicies, [expected])
    XCTAssertTrue(host.confirmations.isEmpty)
  }

  /// Catches a controlled request answered with a plain confirmation, which cannot offer the
  /// session, and a question that names the selected tab instead of the one that asked. The
  /// session answer is passed on as it was given.
  func testAControlledRequestAsksPermissionNamingTheTabItCameFrom() async {
    let (applet, engine, host) = makeApplet()

    engine.sessions[0].onEvent?(.titleChanged("background-tab"))
    applet.openTab()
    engine.sessions[1].onEvent?(.titleChanged("selected-tab"))
    host.permissionAnswer = .allowForSession

    let answers = AnswerLog()
    let request = TerminalClipboardRequest(kind: .write, text: "w", offersSession: true) {
      answers.append($0)
    }

    engine.sessions[0].onEvent?(.clipboardRequest(request))

    await settle { !answers.all.isEmpty }

    XCTAssertEqual(applet.title, "selected-tab")
    XCTAssertEqual(host.permissions.map(\.subject), ["background-tab"])
    XCTAssertEqual(host.permissions.first?.sessionTitle, "Allow Writes in This Tab")
    XCTAssertTrue(host.confirmations.isEmpty)
    XCTAssertEqual(answers.all, [.allowForSession])
  }

  /// Catches a plain read question that names the selected tab when a background tab asked.
  func testAnInteractiveReadNamesTheTabItCameFrom() async {
    let (applet, engine, host) = makeApplet()

    engine.sessions[0].onEvent?(.titleChanged("background-tab"))
    applet.openTab()

    let answers = AnswerLog()
    let request = TerminalClipboardRequest(kind: .read, text: "r") { answers.append($0) }

    engine.sessions[0].onEvent?(.clipboardRequest(request))

    await settle { !answers.all.isEmpty }

    XCTAssertEqual(host.confirmations.map(\.subject), ["background-tab"])
    XCTAssertTrue(host.permissions.isEmpty)
  }
}

private final class AnswerLog: @unchecked Sendable {
  private let lock = NSLock()
  private var answers: [TerminalClipboardAnswer] = []

  func append(_ answer: TerminalClipboardAnswer) {
    lock.lock()
    answers.append(answer)
    lock.unlock()
  }

  var all: [TerminalClipboardAnswer] {
    lock.lock()
    defer { lock.unlock() }
    return answers
  }
}
