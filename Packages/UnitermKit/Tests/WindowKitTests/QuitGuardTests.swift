import AppKit
import AppletKit
import DefaultsTestSupport
import Preferences
import XCTest

@testable import WindowKit

/// Quit asks under the same rule as a window close, across every window. The window set owns the
/// rule, so it is tested here and not through the app delegate.
@MainActor
final class QuitGuardTests: XCTestCase {
  private let testDefaults = TestDefaults(prefix: "uniterm-quit-test")
  private var windows: WindowSet?
  private var asked: [CloseConfirmation] = []
  private var answer = false
  private let log = AppletLog()
  private var made: [FakeApplet] { log.made }

  override func setUp() async throws {
    asked = []
    answer = false
    log.made = []
  }

  override func tearDown() async throws {
    for controller in windows?.controllers ?? [] {
      controller.window?.close()
    }

    windows = nil
    testDefaults.discard()
  }

  private func makeWindows() -> WindowSet {
    let store = SettingsStore(defaults: testDefaults.defaults)
    let appearance = AppearanceController(store: store)
    let log = log

    let set = WindowSet(
      confirmer: { [unowned self] request, _ in
        asked.append(request)
        return answer
      },
      makeController: { identifier, _ in
        try MainWindowController(
          appearance: appearance, settings: store, identifier: identifier
        ) { _, _ in
          let applet = FakeApplet()
          applet.title = "Fake \(log.made.count)"
          log.made.append(applet)
          return applet
        }
      })

    windows = set
    return set
  }

  /// Catches a quit that forgets a window, or counts a pane that is gone. Window one is idle.
  /// Window two has two panes running make and vim. Quit lists both, and nothing from window one. A
  /// third pane running emacs was closed with the user's say, so it is not listed.
  func testQuitCountsEveryWindowsRunningTabs() async throws {
    let set = makeWindows()
    try set.open()
    let second = try set.open()
    made[1].isRunningSomething = true
    made[1].labels = ["make test"]
    second.openPane(.terminalShell, axis: .row)
    made[2].isRunningSomething = true
    made[2].labels = ["vim"]
    second.openPane(.terminalShell, axis: .row)
    made[3].isRunningSomething = true
    made[3].labels = ["emacs"]
    second.confirmer = { _, _ in true }
    second.dispatch(.close)
    await second.pendingGuard?.value

    XCTAssertTrue(made[3].closed)
    XCTAssertEqual(set.runningTabLabels, ["make test", "vim"])
    XCTAssertEqual(second.paneIDs.count, 2)

    answer = false
    let proceed = await set.shouldQuit()

    XCTAssertFalse(proceed)
    XCTAssertEqual(asked.count, 1)
    XCTAssertEqual(asked[0].labels.sorted(), ["make test", "vim"])
    XCTAssertEqual(asked[0].confirmTitle, "Quit")

    answer = true
    let confirmed = await set.shouldQuit()

    XCTAssertTrue(confirmed)
  }

  /// Catches a quit that asks although nothing is running anywhere.
  func testQuitWithNothingRunningAsksNothing() async throws {
    let set = makeWindows()
    try set.open()

    let proceed = await set.shouldQuit()

    XCTAssertTrue(proceed)
    XCTAssertTrue(asked.isEmpty)
  }
}
