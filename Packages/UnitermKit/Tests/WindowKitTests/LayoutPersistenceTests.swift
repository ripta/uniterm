import AppKit
import AppletKit
import LayoutKit
import PaneModel
import Preferences
import StatusKit
import XCTest

@testable import WindowKit

@MainActor
private final class LaunchControls {
  var finishers: [@MainActor () -> Void] = []

  /// The number of the restored window whose controller fails to build. Counts from 1.
  var failingWindow: Int?

  /// Makes the default window fail to build as well, so the launch throws.
  var failingDefault = false
  var restoredWindows = 0
}

/// A window set over fake applets that saves and restores through a layout folder.
///
/// Every fixture over the same folder stands in for one launch of the app. The folder is a scratch
/// directory, the debounce is held by hand, and nothing waits on a real timer.
@MainActor
private final class LaunchFixture {
  static let main = ScreenArea(
    frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
    visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875))

  let suite = "uniterm-layout-test-\(UUID().uuidString)"
  let defaults: UserDefaults
  let scheduler = WakeScheduler()
  let controls = LaunchControls()
  let windows: WindowSet
  let persistence: LayoutPersistence
  let store: LayoutStore

  init(
    directory: URL, screens: [ScreenArea] = [LaunchFixture.main],
    visible: NSRect = NSRect(x: 0, y: 0, width: 4000, height: 3000)
  ) {
    let defaults = UserDefaults(suiteName: suite)!
    let settings = SettingsStore(defaults: defaults)
    let appearance = AppearanceController(store: settings)
    let controls = controls
    self.defaults = defaults

    let restore: AppletRestorer = { description in
      guard description.type == "fake" else {
        throw AppletRestoreError.wrongType(expected: "fake", found: description.type)
      }

      guard description.version <= 1 else {
        throw AppletRestoreError.newerVersion(found: description.version, supported: 1)
      }

      guard case .string(let title) = description.payload else {
        throw AppletRestoreError.corrupt("no title")
      }

      let applet = FakeApplet()
      applet.title = title
      return applet
    }

    let make: AppletFactory = { _, _ in
      let applet = FakeApplet()
      applet.title = "new"
      return applet
    }

    let windows = WindowSet(
      visibleFrame: { _ in visible }, screens: { screens },
      makeRestoredController: { identifier, restored in
        controls.restoredWindows += 1

        if controls.restoredWindows == controls.failingWindow {
          throw AppletRestoreError.unsupported("test failure")
        }

        return try MainWindowController(
          appearance: appearance, settings: settings, identifier: identifier,
          restoring: restored, restoreApplet: restore, makeApplet: make
        ).detachFromRealScreen()
      },
      makeController: { identifier, _ in
        if controls.failingDefault {
          throw AppletRestoreError.unsupported("test failure")
        }

        return try MainWindowController(
          appearance: appearance, settings: settings, identifier: identifier,
          restoreApplet: restore, makeApplet: make
        ).detachFromRealScreen()
      })

    let store = LayoutStore(directory: directory)

    self.windows = windows
    self.store = store
    persistence = LayoutPersistence(
      store: store, windows: windows, scheduler: scheduler.schedule,
      afterLaunch: { controls.finishers.append($0) })
  }

  func cleanUp() {
    for controller in windows.controllers { controller.window?.close() }

    store.release()
    defaults.removePersistentDomain(forName: suite)
  }

  var first: MainWindowController { windows.controllers[0] }

  func messages(of controller: MainWindowController) -> [String] {
    controller.statusCenter.history.map(\.text)
  }
}

@MainActor
final class LayoutPersistenceTests: XCTestCase {
  private var directory: URL!

  override func setUp() async throws {
    directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("uniterm-persist-test-\(UUID().uuidString)", isDirectory: true)
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: directory)
  }

  private func launch(
    screens: [ScreenArea] = [LaunchFixture.main],
    visible: NSRect = NSRect(x: 0, y: 0, width: 4000, height: 3000)
  ) throws -> (LaunchFixture, LayoutPersistence.Outcome) {
    let fixture = LaunchFixture(directory: directory, screens: screens, visible: visible)
    addTeardownBlock { @MainActor in fixture.cleanUp() }

    let outcome = try fixture.persistence.launch()
    return (fixture, outcome)
  }

  private var layoutFile: URL { directory.appendingPathComponent("layout.json") }

  /// The copies the store kept beside the layout file, oldest first.
  private func keptAsideFiles() -> [URL] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []

    return names.filter { $0.hasPrefix("layout.aside-") }.sorted().map {
      directory.appendingPathComponent($0)
    }
  }

  private func plant(_ layout: SavedLayout) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try LayoutCodec.encode(layout).write(to: layoutFile)
  }

  private func titles(of controller: MainWindowController) -> [String] {
    controller.paneArea.applets.map(\.title)
  }

  // MARK: Restore

  /// Catches a relaunch that loses the tree, a weight, an applet description, or the focus. One
  /// launch builds a row of two with the second split into a column, moves the divider, and quits.
  /// The next launch must show the same tree.
  func testQuitAndRelaunchRestoreTheSplitLayout() throws {
    let (first, firstOutcome) = try launch()
    XCTAssertEqual(firstOutcome, .fresh)

    let controller = first.first
    controller.window?.setFrame(NSRect(x: 100, y: 100, width: 960, height: 640), display: false)
    controller.window?.contentView?.layoutSubtreeIfNeeded()

    controller.openPane(.terminalShell, axis: .row)
    controller.openPane(.terminalShell, axis: .column)

    let before = controller.paneArea.tree.root
    let focus = controller.focusedPane
    let frame = controller.window!.frame

    first.persistence.saveForQuit()

    let (second, secondOutcome) = try launch()
    XCTAssertEqual(secondOutcome, .restored(windows: 1))

    let restored = second.first
    XCTAssertEqual(restored.paneArea.tree.root, before)
    XCTAssertEqual(restored.focusedPane, focus)
    XCTAssertEqual(titles(of: restored), ["new", "new", "new"])
    XCTAssertEqual(restored.window?.frame, frame)
    XCTAssertEqual(restored.paneIDs.count, 3)
  }

  /// Catches a restore that gives every pane the description of a fresh pane. The descriptions
  /// are planted by hand with distinct titles, in a two-window layout.
  func testEveryWindowAndPaneComesBackWithItsOwnDescription() throws {
    try plant(
      SavedLayout(windows: [
        savedWindow(
          tree: savedSplit(3, .row, [(savedPane(1, "a"), 0.3), (savedPane(2, "b"), 0.7)]), focus: 2,
          mark: 3),
        savedWindow(
          tree: savedPane(1, "c"), mark: 1, frame: CGRect(x: 300, y: 300, width: 700, height: 500)),
      ]))

    let (fixture, outcome) = try launch()

    XCTAssertEqual(outcome, .restored(windows: 2))
    XCTAssertEqual(fixture.windows.controllers.count, 2)
    XCTAssertEqual(titles(of: fixture.windows.controllers[0]), ["a1", "b2"])
    XCTAssertEqual(titles(of: fixture.windows.controllers[1]), ["c1"])
    XCTAssertEqual(fixture.windows.controllers[0].focusedPane, NodeID(rawValue: 2))
    XCTAssertEqual(fixture.windows.controllers[1].window?.frame.origin, CGPoint(x: 300, y: 300))
  }

  /// A saved layout with no windows opens one default window.
  func testZeroSavedWindowsOpensOneDefaultWindow() throws {
    try plant(SavedLayout(windows: []))

    let (fixture, outcome) = try launch()

    XCTAssertEqual(outcome, .restored(windows: 0))
    XCTAssertEqual(fixture.windows.controllers.count, 1)
    XCTAssertEqual(fixture.first.paneIDs.count, 1)
  }

  /// Catches a window that AppKit would restore a second time.
  func testNoWindowIsLeftToAppKitRestoration() throws {
    let (fixture, _) = try launch()

    XCTAssertEqual(fixture.windows.controllers.map { $0.window?.isRestorable }, [false])
  }

  // MARK: IDs

  /// Catches the reuse of an ID retired before the quit. The first launch splits twice and closes the
  /// newest pane. The closed ID is below the saved mark. After the relaunch, that ID is retired,
  /// and the next split uses a larger ID than anything handed out before.
  func testIDsRetiredBeforeTheQuitAreNeverReissued() throws {
    let (first, _) = try launch()
    let controller = first.first

    let second = controller.openPane(.terminalShell, axis: .row)!
    let third = controller.openPane(.terminalShell, axis: .row)!
    let mark = controller.paneArea.tree.highWaterMark

    controller.paneArea.focus(third)
    controller.dispatch(.close)

    XCTAssertFalse(controller.paneIDs.contains(third))
    XCTAssertEqual(controller.paneArea.tree.highWaterMark, mark)

    first.persistence.saveForQuit()

    let (relaunched, _) = try launch()
    let restored = relaunched.first

    XCTAssertFalse(restored.paneIDs.contains(third))
    XCTAssertTrue(restored.paneIDs.contains(second))
    XCTAssertTrue(restored.paneArea.tree.isRetired(third))
    XCTAssertEqual(restored.paneArea.tree.highWaterMark, mark)

    let created = restored.openPane(.terminalShell, axis: .column)!
    XCTAssertGreaterThan(created.rawValue, mark)
  }

  // MARK: Placeholders

  /// Catches a description that is rewritten, dropped, or run through a double. The planted bytes
  /// hold a number that a double rounds, odd spacing, and a type this build does not know.
  func testAnUnreadableDescriptionBecomesAPlaceholderAndIsWrittenBackUnchanged() throws {
    let raw = #"{ "type":"future", "version":3,  "payload":{"n":12345678901234567890,"z":[1, 2]} }"#

    let future = AppletDescription(
      type: "future", version: 3, payload: .null, verbatim: Data(raw.utf8))

    let newer = AppletDescription(
      type: "fake", version: 9, payload: .string("x"),
      verbatim: Data(#"{"type":"fake","version":9,"payload":"x"}"#.utf8))

    try plant(
      SavedLayout(windows: [
        savedWindow(
          tree: savedSplit(
            3, .row,
            [
              (.pane(id: NodeID(rawValue: 1), applet: future), 0.3), (savedPane(2, "ok"), 0.4),
              (.pane(id: NodeID(rawValue: 4), applet: newer), 0.3),
            ]), mark: 4)
      ]))

    let (fixture, _) = try launch()
    let controller = fixture.first

    XCTAssertEqual(
      controller.paneArea.applets.map(\.typeID), ["placeholder", "fake", "placeholder"])
    XCTAssertTrue(
      fixture.messages(of: controller).contains {
        $0.contains("2 saved panes could not be restored")
      },
      "\(fixture.messages(of: controller))")

    fixture.persistence.saveForQuit()

    let written = String(decoding: try Data(contentsOf: layoutFile), as: UTF8.self)

    XCTAssertTrue(
      written.contains(#""applet":\#(raw)"#), "the future description changed: \(written)")
    XCTAssertTrue(written.contains(#""applet":{"type":"fake","version":9,"payload":"x"}"#))
  }

  // MARK: Recovery

  /// An unreadable file is kept aside, a default window opens, and the user is told.
  func testAnUnreadableFileStartsADefaultLayoutAndSaysSo() throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("garbage".utf8).write(to: layoutFile)

    let (fixture, outcome) = try launch()

    XCTAssertEqual(outcome, .fresh)
    XCTAssertEqual(fixture.windows.controllers.count, 1)
    XCTAssertEqual(keptAsideFiles().count, 1)
    XCTAssertTrue(
      fixture.messages(of: fixture.first).contains { $0.contains("could not be used") })
  }

  /// Catches a restore that crashes again and again. The marker says three launches began and
  /// never finished, so the next launch keeps the file aside and starts a default layout.
  func testALaunchAfterRepeatedCrashesStartsFreshAndKeepsTheFile() throws {
    try plant(
      SavedLayout(windows: [
        savedWindow(tree: savedPane(1, "a")), savedWindow(tree: savedPane(1, "b")),
      ]))
    try Data("3\n".utf8).write(to: directory.appendingPathComponent("launch.marker"))

    let (fixture, outcome) = try launch()

    XCTAssertEqual(outcome, .fresh)
    XCTAssertEqual(fixture.windows.controllers.count, 1)
    XCTAssertEqual(keptAsideFiles().count, 1)
    XCTAssertTrue(
      fixture.messages(of: fixture.first).contains { $0.contains("did not finish starting") })
  }

  /// The marker is set before the restore and cleared only once the launch is done.
  func testTheLaunchMarkerIsClearedOnlyAfterTheLaunchFinishes() throws {
    let (fixture, _) = try launch()
    let marker = directory.appendingPathComponent("launch.marker")

    XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))

    for finish in fixture.controls.finishers { finish() }

    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
  }

  /// A saved window that cannot open is replaced by nothing silently. The file is copied aside
  /// before the next save can overwrite it, and the user is told.
  func testAWindowThatFailsToRestoreKeepsACopyOfTheFile() throws {
    try plant(
      SavedLayout(windows: [
        savedWindow(tree: savedPane(1, "a")), savedWindow(tree: savedPane(1, "b")),
      ]))
    let original = try Data(contentsOf: layoutFile)

    let fixture = LaunchFixture(directory: directory)
    addTeardownBlock { @MainActor in fixture.cleanUp() }
    fixture.controls.failingWindow = 2

    XCTAssertEqual(try fixture.persistence.launch(), .restored(windows: 1))
    XCTAssertEqual(fixture.windows.controllers.count, 1)
    XCTAssertEqual(try Data(contentsOf: keptAsideFiles()[0]), original)
    XCTAssertTrue(
      fixture.messages(of: fixture.first).contains { $0.contains("did not reopen") })
  }

  /// Catches a launch that throws after the marker was set. The app quits, and three such
  /// launches in a row would move a valid layout aside as if the app had crashed.
  func testALaunchThatCannotOpenAnyWindowLeavesNoMarker() throws {
    try plant(SavedLayout(windows: [savedWindow(tree: savedPane(1, "a"))]))

    let fixture = LaunchFixture(directory: directory)
    addTeardownBlock { @MainActor in fixture.cleanUp() }
    fixture.controls.failingWindow = 1
    fixture.controls.failingDefault = true

    XCTAssertThrowsError(try fixture.persistence.launch())
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: directory.appendingPathComponent("launch.marker").path)
    )
  }

  // MARK: Pending open

  /// Catches a cold launch that opens a default shell beside a routed open. Each launch outcome
  /// that would open a default window must open none while an open waits. The caller then makes
  /// the window from the open.
  func testAPendingOpenSkipsTheDefaultWindowOnEveryOutcome() throws {
    func launchWithPending(_ directory: URL) throws -> (LaunchFixture, LayoutPersistence.Outcome) {
      let fixture = LaunchFixture(directory: directory)
      addTeardownBlock { @MainActor in fixture.cleanUp() }

      return (fixture, try fixture.persistence.launch(hasPendingOpen: { true }))
    }

    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("garbage".utf8).write(to: layoutFile)
    let (fresh, freshOutcome) = try launchWithPending(directory)
    XCTAssertEqual(freshOutcome, .fresh)
    XCTAssertTrue(fresh.windows.controllers.isEmpty)
    fresh.persistence.saveForQuit()

    try FileManager.default.removeItem(at: directory)
    try plant(SavedLayout(windows: []))
    let (empty, emptyOutcome) = try launchWithPending(directory)
    XCTAssertEqual(emptyOutcome, .restored(windows: 0))
    XCTAssertTrue(empty.windows.controllers.isEmpty)
    empty.persistence.saveForQuit()

    let (_, secondOutcome) = try launchWithPending(directory)
    let (second, secondInstance) = try launchWithPending(directory)
    XCTAssertEqual(secondOutcome, .restored(windows: 0))
    XCTAssertEqual(secondInstance, .secondInstance)
    XCTAssertTrue(second.windows.controllers.isEmpty)
  }

  /// Catches a pending open that suppresses saved windows. They still restore as saved.
  func testAPendingOpenStillRestoresSavedWindows() throws {
    try plant(SavedLayout(windows: [savedWindow(tree: savedPane(1, "a"))]))

    let fixture = LaunchFixture(directory: directory)
    addTeardownBlock { @MainActor in fixture.cleanUp() }

    let outcome = try fixture.persistence.launch(hasPendingOpen: { true })

    XCTAssertEqual(outcome, .restored(windows: 1))
    XCTAssertEqual(fixture.windows.controllers.count, 1)
  }

  /// Catches a layout folder that cannot be used, which must also leave the window to the open.
  func testAPendingOpenSkipsTheDefaultWindowWhenTheLayoutIsUnavailable() throws {
    try Data("not a folder".utf8).write(to: directory)

    let fixture = LaunchFixture(directory: directory)
    addTeardownBlock { @MainActor in fixture.cleanUp() }

    let outcome = try fixture.persistence.launch(hasPendingOpen: { true })

    XCTAssertEqual(outcome, .unavailable)
    XCTAssertTrue(fixture.windows.controllers.isEmpty)
  }

  // MARK: Saving

  /// Catches a launch that saves a half-restored layout. Restoring two windows changes the
  /// layout twice, and no save may be pending afterwards.
  func testRestoringSchedulesNoSave() throws {
    try plant(
      SavedLayout(windows: [
        savedWindow(tree: savedPane(1, "a")), savedWindow(tree: savedPane(1, "b")),
      ]))

    let (fixture, _) = try launch()

    XCTAssertTrue(fixture.scheduler.pending.isEmpty)
  }

  /// A change waits for the debounce and then lands in the file.
  func testALayoutChangeIsWrittenAfterTheDebounce() throws {
    let (fixture, _) = try launch()

    fixture.first.openPane(.terminalShell, axis: .row)

    XCTAssertFalse(FileManager.default.fileExists(atPath: layoutFile.path))
    XCTAssertTrue(fixture.scheduler.pending.values.contains { $0.delay == 1 })

    fixture.scheduler.fire()

    let saved = try LayoutCodec.decode(try Data(contentsOf: layoutFile))
    XCTAssertEqual(saved.windows[0].tree.paneIDs.count, 2)
  }

  /// Catches a quit that drops a change made an instant before it. The change is never given
  /// time to debounce.
  func testAChangeMadeJustBeforeQuitStillRestores() throws {
    let (first, _) = try launch()
    first.first.openPane(.terminalShell, axis: .row)

    XCTAssertFalse(first.scheduler.pending.isEmpty, "the debounce has not fired")

    first.persistence.saveForQuit()

    let (second, _) = try launch()
    XCTAssertEqual(second.first.paneIDs.count, 2)
  }

  /// Catches a title that animates starving the saver. A title change that leaves the saved
  /// description the same is not a layout change. A change to the description still is.
  func testATitleOnlyChangeIsNotALayoutChange() throws {
    let (fixture, _) = try launch()
    let controller = fixture.first
    var changes = 0
    fixture.windows.onLayoutChange = { changes += 1 }

    let applet = try XCTUnwrap(controller.paneArea.applets.first as? FakeApplet)
    applet.fixedDescription = AppletDescription(type: "fake", version: 1, payload: .string("a"))
    _ = controller.savedWindow()
    changes = 0

    applet.title = "spinner 1"
    controller.appletDidChange(applet)
    applet.title = "spinner 2"
    controller.appletDidChange(applet)

    XCTAssertEqual(changes, 0)

    applet.fixedDescription = AppletDescription(type: "fake", version: 1, payload: .string("b"))
    controller.appletDidChange(applet)

    XCTAssertEqual(changes, 1)
  }

  /// Closing every window and quitting saves no windows, and the next launch opens one.
  func testClosingEveryWindowThenQuittingOpensOneDefaultWindowNextTime() throws {
    let (first, _) = try launch()
    first.first.window?.close()
    first.persistence.saveForQuit()

    let saved = try LayoutCodec.decode(try Data(contentsOf: layoutFile))
    XCTAssertTrue(saved.windows.isEmpty)

    let (second, outcome) = try launch()
    XCTAssertEqual(outcome, .restored(windows: 0))
    XCTAssertEqual(second.windows.controllers.count, 1)
  }

  /// Catches a second instance that overwrites the first one's layout.
  func testASecondInstanceNeverOverwritesTheFirstInstancesLayout() throws {
    let (first, _) = try launch()
    first.first.openPane(.terminalShell, axis: .row)
    first.scheduler.fire()

    let written = try Data(contentsOf: layoutFile)

    let (second, outcome) = try launch()
    XCTAssertEqual(outcome, .secondInstance)
    XCTAssertTrue(
      second.messages(of: second.first).contains { $0.contains("Another uniterm is running") })

    second.first.openPane(.terminalShell, axis: .column)
    second.first.openPane(.terminalShell, axis: .column)

    XCTAssertTrue(second.scheduler.pending.isEmpty, "the second instance schedules no save")

    second.persistence.saveForQuit()

    XCTAssertEqual(try Data(contentsOf: layoutFile), written)
  }

  // MARK: Placement

  /// Catches a window restored onto a screen that is gone. It must land fully on the one left.
  func testAWindowFromAGoneScreenOpensFullyOnAVisibleScreen() throws {
    try plant(
      SavedLayout(windows: [
        savedWindow(
          tree: savedPane(1), frame: CGRect(x: 3200, y: 400, width: 800, height: 600))
      ]))

    let (fixture, _) = try launch()
    let frame = try XCTUnwrap(fixture.first.window?.frame)

    XCTAssertTrue(LaunchFixture.main.visibleFrame.contains(frame), "\(frame)")
    XCTAssertEqual(frame.size, CGSize(width: 800, height: 600))
  }

  /// A tree that needs more room than the screen has still opens inside the screen. The window
  /// does not demand a size beyond the visible area.
  func testATreeWiderThanTheScreenStillOpensInsideTheScreen() throws {
    let panes = (1...6).map { (savedPane(UInt64($0)), 1.0 / 6) }
    let tree = savedSplit(7, .row, panes)

    try plant(
      SavedLayout(windows: [
        savedWindow(tree: tree, mark: 7, frame: CGRect(x: 0, y: 0, width: 4000, height: 700))
      ]))

    let visible = NSRect(x: 0, y: 0, width: 1000, height: 700)
    let (fixture, _) = try launch(
      screens: [ScreenArea(frame: visible, visibleFrame: visible)], visible: visible)
    let controller = fixture.first
    let frameWindow = try XCTUnwrap(controller.window)

    XCTAssertGreaterThan(controller.paneArea.minimumSize.width, 1000, "the tree needs 1225")
    XCTAssertLessThanOrEqual(frameWindow.contentMinSize.width, 1000)
    XCTAssertLessThanOrEqual(frameWindow.frame.width, 1000)
    XCTAssertEqual(controller.paneIDs.count, 6)
  }
}
