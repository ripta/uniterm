import AppKit
import AppletKit
import PaneModel
import Preferences
import StatusKit
import Theme
import XCTest

@testable import WindowKit

/// Several windows over one settings store and one appearance controller, as the app has them.
@MainActor
private final class WindowSetFixture {
  let suite = "uniterm-windowset-test-\(UUID().uuidString)"
  let defaults: UserDefaults
  let store: SettingsStore
  let appearance: AppearanceController
  let log = AppletLog()
  let windows: WindowSet

  init(visibleFrame: NSRect? = NSRect(x: 0, y: 0, width: 4000, height: 3000)) {
    let defaults = UserDefaults(suiteName: suite)!
    let store = SettingsStore(defaults: defaults)
    let appearance = AppearanceController(store: store)
    let log = log

    self.defaults = defaults
    self.store = store
    self.appearance = appearance

    let makeApplet: AppletFactory = { _, directory in
      log.requested.append(directory)

      let applet = FakeApplet()
      log.made.append(applet)
      return applet
    }

    windows = WindowSet(
      visibleFrame: { _ in visibleFrame },
      makeController: { identifier, directory in
        try MainWindowController(
          appearance: appearance, settings: store, identifier: identifier, startingIn: directory,
          makeApplet: makeApplet
        ).detachFromRealScreen()
      })
  }

  func cleanUp() {
    for controller in windows.controllers {
      controller.window?.close()
    }

    store.set(.system, for: .appearance)
    defaults.removePersistentDomain(forName: suite)
  }

  func edge(_ controller: MainWindowController) -> DockEdge? {
    controller.contentController.edge(of: .statusBar)
  }

  func messageText(_ controller: MainWindowController) -> String? {
    controller.contentController.statusBar.segments.first { $0.id == .message }?.text
  }
}

@MainActor
final class WindowSetTests: XCTestCase {
  private func makeFixture(visibleFrame: NSRect? = NSRect(x: 0, y: 0, width: 4000, height: 3000))
    -> WindowSetFixture
  {
    let fixture = WindowSetFixture(visibleFrame: visibleFrame)
    addTeardownBlock { @MainActor in fixture.cleanUp() }
    return fixture
  }

  // MARK: Window states

  /// Catches a window state that reaches only the windows open when it was set, or one that
  /// outlives its feature. Every open window shows a state at once, a window opened later shows
  /// it too, and clearing it empties them all. A kind with no producer yet shows when set.
  func testAWindowStateReachesEveryWindowIncludingLaterOnes() throws {
    let fixture = makeFixture()
    let first = try fixture.windows.open()

    func slots(_ controller: MainWindowController) -> [BarSegmentID] {
      controller.statusBarSegments.map(\.id).filter {
        if case .window = $0 { return true }
        return false
      }
    }

    XCTAssertTrue(slots(first).isEmpty)

    fixture.windows.setWindowState(.survivingWork, text: "Work is still running.")

    let second = try fixture.windows.open()
    fixture.windows.setWindowState(.layoutNotSaved, text: "Not saved.")

    for controller in [first, second] {
      XCTAssertEqual(slots(controller), [.window(.layoutNotSaved), .window(.survivingWork)])
      XCTAssertEqual(
        controller.contentController.statusBar.segments.map(\.id).filter {
          slots(controller).contains($0)
        },
        slots(controller), "the bar shows what the window computed")
    }

    fixture.windows.clearWindowState(.layoutNotSaved)
    fixture.windows.clearWindowState(.survivingWork)

    XCTAssertTrue(slots(first).isEmpty)
    XCTAssertTrue(slots(second).isEmpty)
  }

  // MARK: Cascade

  /// Catches a cascade that steps the wrong way or the wrong distance.
  ///
  /// A window at x 100 with its top at 100 + 640 = 740 steps 28 right and 28 down to (128, 712).
  func testACascadeStepsRightAndDown() {
    let corner = WindowCascade.topLeft(
      after: NSRect(x: 100, y: 100, width: 960, height: 640), size: NSSize(width: 960, height: 640),
      in: NSRect(x: 0, y: 0, width: 1920, height: 1080))

    XCTAssertEqual(corner, NSPoint(x: 128, y: 712))
  }

  /// Catches a cascade that walks off the right or bottom edge of the screen.
  ///
  /// Anchor x 1000 steps to 1028, and 1028 + 960 = 1988 passes 1920. Anchor top 600 steps to 572,
  /// and 572 - 640 passes the bottom at 0. Both wrap to the visible frame's top-left, (0, 1080).
  func testACascadeWrapsToTheTopLeftWhenItWouldLeaveTheScreen() {
    let visible = NSRect(x: 0, y: 0, width: 1920, height: 1080)
    let size = NSSize(width: 960, height: 640)

    XCTAssertEqual(
      WindowCascade.topLeft(
        after: NSRect(x: 1000, y: 100, width: 960, height: 640), size: size, in: visible),
      NSPoint(x: 0, y: 1080))
    XCTAssertEqual(
      WindowCascade.topLeft(
        after: NSRect(x: 100, y: 0, width: 960, height: 600), size: size, in: visible),
      NSPoint(x: 0, y: 1080))
  }

  /// Catches a wrap that fires on an exact fit.
  ///
  /// Anchor x 932 steps to 960, and 960 + 960 = 1920 touches the edge without passing it.
  func testACascadeThatTouchesTheEdgeStays() {
    let corner = WindowCascade.topLeft(
      after: NSRect(x: 932, y: 100, width: 960, height: 640), size: NSSize(width: 960, height: 640),
      in: NSRect(x: 0, y: 0, width: 1920, height: 1080))

    XCTAssertEqual(corner, NSPoint(x: 960, y: 712))
  }

  /// Catches a new window that opens on top of the active one, hiding it.
  ///
  /// The second window sits 28 right and 28 down from the first, and the third from the second.
  func testNewWindowsCascadeFromTheActiveWindow() throws {
    let fixture = makeFixture()

    let first = try fixture.windows.open()
    let second = try fixture.windows.open()
    let third = try fixture.windows.open()

    let one = try XCTUnwrap(first.window).frame
    let two = try XCTUnwrap(second.window).frame
    let three = try XCTUnwrap(third.window).frame

    XCTAssertEqual(two.minX, one.minX + 28)
    XCTAssertEqual(two.maxY, one.maxY - 28)
    XCTAssertEqual(three.minX, two.minX + 28)
    XCTAssertEqual(three.maxY, two.maxY - 28)
  }

  // MARK: Identity

  /// Catches windows that share an accessibility identifier, which tests and assistive tools use to
  /// tell them apart.
  ///
  /// The first keeps the plain name. Later ones carry their number, and a number is never reused
  /// after a close.
  func testEachWindowHasItsOwnIdentifierAndNumbersAreNeverReused() throws {
    let fixture = makeFixture()

    let first = try fixture.windows.open()
    let second = try fixture.windows.open()
    XCTAssertEqual(first.window?.accessibilityIdentifier(), "main-window")
    XCTAssertEqual(second.window?.accessibilityIdentifier(), "main-window-2")

    second.window?.close()
    let third = try fixture.windows.open()
    XCTAssertEqual(third.window?.accessibilityIdentifier(), "main-window-3")
  }

  // MARK: Directory

  /// Catches a new window that starts wherever the app was launched, or in a directory libghostty
  /// remembers. The active window's focused applet reports /tmp, so the new window's first pane is
  /// asked to start there. The first window has no active window to follow.
  func testANewWindowStartsInTheDirectoryTheActiveWindowReports() throws {
    let fixture = makeFixture()
    _ = try fixture.windows.open()
    fixture.log.made[0].currentDirectory = "/tmp"

    _ = try fixture.windows.open()

    XCTAssertEqual(fixture.log.requested, [nil, "/tmp"])
  }

  /// Catches a new window that invents a directory when the focused applet reports none.
  func testANewWindowFromAPaneWithNoDirectoryAsksForNone() throws {
    let fixture = makeFixture()
    _ = try fixture.windows.open()

    _ = try fixture.windows.open()

    XCTAssertEqual(fixture.log.requested, [nil, nil])
  }

  // MARK: Isolation

  /// Catches windows that share a pane tree.
  ///
  /// Splitting the second window adds a pane there. The first keeps its one pane, and each window
  /// has its own applets.
  func testEachWindowHasItsOwnPaneTree() throws {
    let fixture = makeFixture()
    let first = try fixture.windows.open()
    let second = try fixture.windows.open()

    second.openPane(.terminalShell, axis: .row)

    XCTAssertEqual(first.paneIDs, [NodeID(rawValue: 1)])
    XCTAssertEqual(second.paneIDs, [NodeID(rawValue: 1), NodeID(rawValue: 2)])
    XCTAssertEqual(fixture.log.made.count, 3)
    XCTAssertTrue(first.paneArea !== second.paneArea)
  }

  /// Catches a status center shared between windows, so a message shows in all of them.
  ///
  /// A message from the second window's applet reaches its bar and history and nothing of the
  /// first's. A message posted to the first's center stays out of the second the same way.
  func testAMessagePostedInOneWindowNeverAppearsInAnother() throws {
    let fixture = makeFixture()
    let first = try fixture.windows.open()
    let second = try fixture.windows.open()
    let secondApplet = fixture.log.made[1]

    secondApplet.say(.error, "from the second")

    XCTAssertEqual(second.statusCenter.history.map(\.text), ["from the second"])
    XCTAssertEqual(fixture.messageText(second), "Fake: from the second")
    XCTAssertTrue(first.statusCenter.history.isEmpty)
    XCTAssertEqual(fixture.messageText(first), "")
    XCTAssertFalse(first.statusCenter.hasUnseenError)

    first.statusCenter.post(level: .warning, text: "from the first")

    XCTAssertEqual(first.statusCenter.history.map(\.text), ["from the first"])
    XCTAssertEqual(second.statusCenter.history.map(\.text), ["from the second"])
  }

  /// Catches a pane action that reaches another window's panes.
  ///
  /// The window controller owns the action and acts on its own tree, so a split in the first leaves
  /// the second alone. Only the closed pane's applet is closed.
  func testPaneActionsActOnTheirOwnWindowOnly() throws {
    let fixture = makeFixture()
    let first = try fixture.windows.open()
    let second = try fixture.windows.open()

    first.openPane(.terminalShell, axis: .row)
    first.dispatch(.close)

    XCTAssertEqual(first.paneIDs, [NodeID(rawValue: 1)])
    XCTAssertEqual(second.paneIDs, [NodeID(rawValue: 1)])
    XCTAssertFalse(fixture.log.made[0].closed)
    XCTAssertTrue(fixture.log.made[2].closed)
    XCTAssertFalse(fixture.log.made[1].closed)
  }

  // MARK: Settings reach every window

  /// Catches a dock change that moves one window's bar and leaves the others behind.
  ///
  /// A window opened after the change starts on the new edge too.
  func testChangingTheDockPositionMovesEveryOpenWindowAtOnce() async throws {
    let fixture = makeFixture()
    let windows = [try fixture.windows.open(), try fixture.windows.open()]
    XCTAssertEqual(windows.map(fixture.edge), [.bottom, .bottom])

    fixture.store.set(.top, for: .statusBarPosition)
    let moved = await waitUntil { windows.allSatisfy { fixture.edge($0) == .top } }
    XCTAssertTrue(moved, "a bar stayed behind: \(windows.map(fixture.edge))")

    let later = try fixture.windows.open()
    XCTAssertEqual(fixture.edge(later), .top)

    fixture.store.set(.bottom, for: .statusBarPosition)
    let back = await waitUntil { (windows + [later]).allSatisfy { fixture.edge($0) == .bottom } }
    XCTAssertTrue(back)
  }

  /// Catches an appearance change that reaches only one window's chrome.
  ///
  /// Mocha's base color is not Latte's, so a window that missed the change shows the old one.
  func testAnAppearanceChangeReachesEveryOpenWindow() async throws {
    let fixture = makeFixture()
    fixture.store.set(.light, for: .appearance)
    let settled = await waitUntil { fixture.appearance.palette == .latte }
    XCTAssertTrue(settled)

    let windows = [try fixture.windows.open(), try fixture.windows.open()]
    let latte = ThemePalette.latte[.base].nsColor
    let mocha = ThemePalette.mocha[.base].nsColor
    XCTAssertNotEqual(latte, mocha)
    XCTAssertEqual(windows.map { $0.window?.backgroundColor }, [latte, latte])

    fixture.store.set(.dark, for: .appearance)
    let changed = await waitUntil { windows.allSatisfy { $0.window?.backgroundColor == mocha } }

    XCTAssertTrue(changed, "a window kept the old colors")
  }

  // MARK: Lifecycle

  /// Catches a closed window that leaks its controller, or leaves its applets running.
  ///
  /// Closing the first window closes both of its applets and drops its controller, which the weak
  /// reference shows. The second window and its applet are untouched.
  func testClosingAWindowClosesItsAppletsAndReleasesItsController() async throws {
    let fixture = makeFixture()
    weak var released: MainWindowController?

    do {
      let first = try fixture.windows.open()
      first.openPane(.terminalShell, axis: .row)
      released = first
    }

    let survivor = try fixture.windows.open()
    let (one, two, other) = (fixture.log.made[0], fixture.log.made[1], fixture.log.made[2])
    XCTAssertEqual(fixture.windows.controllers.count, 2)

    released?.window?.close()

    XCTAssertTrue(one.closed)
    XCTAssertTrue(two.closed)
    XCTAssertFalse(other.closed)
    XCTAssertTrue(fixture.windows.controllers == [survivor])

    let gone = await waitUntil { released == nil }
    XCTAssertTrue(gone, "the closed window's controller was never released")
    XCTAssertFalse(other.closed)
  }

  /// Catches a session report that names the wrong window or pane, and a window close that never
  /// reaches the script host, which would leave grants to the window's panes standing. An applet's
  /// session start and end arrive with its window's script ID and its pane, and the close arrives
  /// with the same ID once the window's applets have closed.
  func testSessionReportsAndAWindowCloseReachTheWiredHandlersWithTheWindowsID() throws {
    let fixture = makeFixture()
    var started: [(UInt64, NodeID, pid_t)] = []
    var ended: [(UInt64, NodeID, pid_t)] = []
    var closed: [UInt64] = []
    var appletClosedFirst: Bool?

    fixture.windows.wireSessionReporting(
      onStarted: { window, pane, _, pid, _, _ in started.append((window, pane, pid)) },
      onEnded: { window, pane, _, pid, _ in ended.append((window, pane, pid)) },
      onWindowClosed: {
        closed.append($0)
        appletClosedFirst = fixture.log.made.last?.closed
      })

    _ = try fixture.windows.open()

    let controller = try fixture.windows.open()
    let applet = try XCTUnwrap(fixture.log.made.last)
    let pane = try XCTUnwrap(controller.paneIDs.first)
    let host = try XCTUnwrap(applet.host)

    host.applet(applet, sessionStarted: AppletTabID.make(), pid: 41, started: 1, generation: 1)
    host.applet(applet, sessionEnded: AppletTabID.make(), pid: 41, started: 1)

    XCTAssertEqual(started.map(\.0), [controller.scriptWindowID])
    XCTAssertEqual(started.map(\.1), [pane])
    XCTAssertEqual(started.map(\.2), [41])
    XCTAssertEqual(ended.map(\.0), [controller.scriptWindowID])
    XCTAssertEqual(ended.map(\.1), [pane])

    controller.window?.close()

    XCTAssertEqual(closed, [controller.scriptWindowID])
    XCTAssertEqual(appletClosedFirst, true, "the window reported its close before its applets")
  }

  /// Catches a set that cannot open a window once the last one has closed.
  ///
  /// The set is empty after the last close, and opening again works with the next number.
  func testTheLastWindowClosingLeavesAnEmptySetThatCanOpenAgain() throws {
    let fixture = makeFixture()
    let only = try fixture.windows.open()

    only.window?.close()

    XCTAssertTrue(fixture.windows.controllers.isEmpty)
    XCTAssertNil(fixture.windows.activeController)

    let next = try fixture.windows.open()
    XCTAssertEqual(next.window?.accessibilityIdentifier(), "main-window-2")
    XCTAssertEqual(fixture.windows.controllers.count, 1)
    XCTAssertTrue(next.window?.isVisible == true)
  }

  // MARK: Reopen

  /// Catches a Dock click that leaves the app with no window, or one that stacks a second window
  /// on top of an open one.
  ///
  /// With no window open, one opens. With one open, nothing opens. A plain window that is not a
  /// main window, as the Settings window is not, does not count as one.
  func testAReopenOpensAWindowOnlyWhenNoMainWindowIsOpen() throws {
    let fixture = makeFixture()
    let settings = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
      backing: .buffered, defer: false)
    settings.isReleasedWhenClosed = false
    settings.makeKeyAndOrderFront(nil)
    addTeardownBlock { @MainActor in settings.close() }

    XCTAssertTrue(try fixture.windows.openIfNone())
    XCTAssertEqual(fixture.windows.controllers.count, 1)

    XCTAssertFalse(try fixture.windows.openIfNone())
    XCTAssertEqual(fixture.windows.controllers.count, 1)

    fixture.windows.controllers[0].window?.close()
    XCTAssertTrue(try fixture.windows.openIfNone())
    XCTAssertEqual(
      fixture.windows.controllers.first?.window?.accessibilityIdentifier(), "main-window-2")
  }

  // MARK: Failed opens

  /// Catches a failed open that burns a window number.
  ///
  /// The first attempt fails, so the first window that opens is still the first and takes the
  /// plain name. The next one is the second.
  func testAFailedOpenDoesNotSkipANumber() throws {
    struct Refused: Error {}

    final class Switch { var fails = true }
    let flag = Switch()
    let fixture = makeFixture()
    let windows = WindowSet { identifier, _ in
      if flag.fails { throw Refused() }

      return try MainWindowController(
        appearance: fixture.appearance, settings: fixture.store, identifier: identifier,
        makeApplet: { _, _ in FakeApplet() })
    }
    addTeardownBlock { @MainActor in
      for controller in windows.controllers { controller.window?.close() }
    }

    XCTAssertThrowsError(try windows.open())
    XCTAssertTrue(windows.controllers.isEmpty)

    flag.fails = false
    let first = try windows.open()
    let second = try windows.open()

    XCTAssertEqual(first.window?.accessibilityIdentifier(), "main-window")
    XCTAssertEqual(second.window?.accessibilityIdentifier(), "main-window-2")
  }

  // MARK: Messages with no window

  /// Catches an app-level error that vanishes because no window was open to show it.
  ///
  /// A message posted with no window is held. The next window that opens gets it once, and a
  /// window opened after that does not.
  func testAMessageWithNoWindowWaitsForTheNextWindow() throws {
    let fixture = makeFixture()

    fixture.windows.post(level: .error, text: "colors failed")

    let first = try fixture.windows.open()
    XCTAssertEqual(first.statusCenter.history.map(\.text), ["colors failed"])

    let second = try fixture.windows.open()
    XCTAssertTrue(second.statusCenter.history.isEmpty)
  }

  /// Catches a held list that grows without bound while no window is open. 40 posts leave the
  /// newest 32 and one message that counts the 8 dropped. The next window gets them as the host's.
  func testHeldMessagesAreBoundedAndCarryTheHostIdentity() throws {
    let fixture = makeFixture()

    for index in 0..<40 {
      fixture.windows.post(level: .info, text: "h\(index)")
    }

    let first = try fixture.windows.open()

    XCTAssertEqual(first.statusCenter.history.count, 33)
    XCTAssertEqual(
      first.statusCenter.history.first?.text, "8 messages were dropped while no window was open.")
    XCTAssertEqual(first.statusCenter.history.dropFirst().first?.text, "h8")
    XCTAssertTrue(first.statusCenter.history.allSatisfy { $0.source == .uniterm })
  }

  /// Catches an error that is lost while info could go instead. An error held first survives 40
  /// later infos, and a lost info does not raise the summary above info.
  func testAHeldErrorOutlivesLaterInfosPastTheLimit() throws {
    let fixture = makeFixture()
    fixture.windows.post(level: .error, text: "colors failed")

    for index in 0..<40 {
      fixture.windows.post(level: .info, text: "h\(index)")
    }

    let first = try fixture.windows.open()
    let history = first.statusCenter.history

    XCTAssertTrue(history.contains { $0.text == "colors failed" && $0.level == .error })
    XCTAssertEqual(history.first?.level, .info)
    XCTAssertEqual(history.count, 33)
  }

  /// Catches an error that goes with no mark when the held list holds nothing else. The summary
  /// carries the error level.
  func testAnErrorLostFromTheHeldListIsCountedAtErrorLevel() throws {
    let fixture = makeFixture()

    for index in 0..<33 {
      fixture.windows.post(level: .error, text: "e\(index)")
    }

    let first = try fixture.windows.open()

    XCTAssertEqual(first.statusCenter.history.first?.level, .error)
    XCTAssertEqual(
      first.statusCenter.history.first?.text, "1 message was dropped while no window was open.")
  }

  /// Catches a message that is held although a window is open to show it, or that reaches the
  /// wrong window.
  ///
  /// With two windows open, the message goes to the active one only.
  func testAMessageWithAWindowOpenGoesToTheActiveWindowOnly() throws {
    let fixture = makeFixture()
    let first = try fixture.windows.open()
    let second = try fixture.windows.open()
    let active = try XCTUnwrap(fixture.windows.activeController)
    let other = active === first ? second : first

    fixture.windows.post(level: .warning, text: "now")

    XCTAssertEqual(active.statusCenter.history.map(\.text), ["now"])
    XCTAssertTrue(other.statusCenter.history.isEmpty)

    let later = try fixture.windows.open()
    XCTAssertTrue(later.statusCenter.history.isEmpty)
  }

  // MARK: Launch anchor

  /// Catches an anchor that follows creation order, not key order. The first window was key last,
  /// so a Launch Services open anchors there though the second is newer.
  func testTheLaunchAnchorIsTheFocusedPaneOfTheWindowThatWasKeyLast() throws {
    let fixture = makeFixture()
    let first = try fixture.windows.open()
    let second = try fixture.windows.open()

    fixture.windows.noteKey(second)
    fixture.windows.noteKey(first)

    let anchor = try XCTUnwrap(fixture.windows.launchAnchor())
    XCTAssertTrue(anchor.controller === first)
    XCTAssertEqual(anchor.pane, first.focusedPane)
  }

  /// Catches a closed window that stays the anchor. The next most recent key window takes over,
  /// and with none ever key the newest window does.
  func testTheAnchorFallsBackWhenTheKeyWindowCloses() throws {
    let fixture = makeFixture()
    let first = try fixture.windows.open()
    let second = try fixture.windows.open()
    let third = try fixture.windows.open()

    fixture.windows.noteKey(first)
    fixture.windows.noteKey(second)
    second.window?.close()

    XCTAssertTrue(fixture.windows.launchAnchorController === first)

    first.window?.close()

    XCTAssertTrue(fixture.windows.launchAnchorController === third)
  }

  func testNoWindowMeansNoAnchor() {
    XCTAssertNil(makeFixture().windows.launchAnchor())
  }

  /// Catches a Finder open that leaves its window minimized, or one that restores it without
  /// making it key. The fake reports itself minimized and records what it is asked to do.
  func testBringingAWindowForwardUnminimizesItAndMakesItKey() {
    let window = FakeForwardable(isMiniaturized: true)

    WindowSet.bringForward(window)

    XCTAssertEqual(window.calls, ["deminiaturize", "makeKeyAndOrderFront"])
  }

  /// A window that is not minimized is only made key.
  func testBringingAnOpenWindowForwardOnlyMakesItKey() {
    let window = FakeForwardable(isMiniaturized: false)

    WindowSet.bringForward(window)

    XCTAssertEqual(window.calls, ["makeKeyAndOrderFront"])
  }
}

@MainActor
private final class FakeForwardable: ForwardableWindow {
  let isMiniaturized: Bool
  var calls: [String] = []

  init(isMiniaturized: Bool) {
    self.isMiniaturized = isMiniaturized
  }

  func deminiaturize(_ sender: Any?) { calls.append("deminiaturize") }
  func makeKeyAndOrderFront(_ sender: Any?) { calls.append("makeKeyAndOrderFront") }
}
