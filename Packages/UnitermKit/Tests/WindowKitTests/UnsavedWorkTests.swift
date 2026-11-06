import AppKit
import AppletKit
import Preferences
import XCTest

@testable import WindowKit

/// Closing with unsaved work: a pane, a window, and quit each ask Save, Don't Save, or Cancel,
/// and only a save that worked, or the user letting the work go, lets the close go on.
@MainActor
final class UnsavedWorkTests: XCTestCase {
  private let suite = "uniterm-unsaved-test-\(UUID().uuidString)"
  private var windows: WindowSet?
  private var asked: [UnsavedQuestion] = []
  private var answer = UnsavedAnswer.cancel
  private let log = AppletLog()
  private var made: [FakeApplet] { log.made }

  override func tearDown() async throws {
    for controller in windows?.controllers ?? [] {
      controller.window?.close()
    }

    windows = nil
    UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
  }

  private func makeWindows() -> WindowSet {
    let store = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
    let appearance = AppearanceController(store: store)
    let log = log

    let set = WindowSet(
      confirmer: { _, _ in true },
      unsavedConfirmer: { [unowned self] question, _ in
        asked.append(question)
        return answer
      },
      makeController: { identifier, _ in
        try MainWindowController(
          appearance: appearance, settings: store, identifier: identifier
        ) { _, _ in
          let applet = FakeApplet()
          log.made.append(applet)
          return applet
        }
      })

    windows = set
    return set
  }

  /// Opens a window with two panes, the second holding unsaved work.
  private func twoPanes() throws -> MainWindowController {
    let set = makeWindows()
    let controller = try set.open()
    controller.unsavedConfirmer = { [unowned self] question, _ in
      asked.append(question)
      return answer
    }
    controller.openPane(.terminalShell, axis: .row)
    made[1].unsavedWork = AppletUnsavedWork(label: "places.geojson")

    return controller
  }

  /// Catches a close that drops unsaved work without asking, or one that goes ahead after Cancel
  /// or after a failed save. Cancel keeps the pane, a failed save keeps it, and a save that works
  /// closes it.
  func testClosingAPaneWithUnsavedWorkAsksAndSaves() async throws {
    let controller = try twoPanes()

    answer = .cancel
    controller.dispatch(.close)
    await controller.pendingGuard?.value

    XCTAssertEqual(asked.map(\.labels), [["places.geojson"]])
    XCTAssertEqual(controller.paneIDs.count, 2)
    XCTAssertEqual(made[1].saves, 0)

    answer = .save
    made[1].saveSucceeds = false
    controller.dispatch(.close)
    await controller.pendingGuard?.value

    XCTAssertEqual(made[1].saves, 1)
    XCTAssertEqual(controller.paneIDs.count, 2)

    made[1].saveSucceeds = true
    controller.dispatch(.close)
    await controller.pendingGuard?.value

    XCTAssertEqual(made[1].saves, 2)
    XCTAssertEqual(controller.paneIDs.count, 1)
    XCTAssertTrue(made[1].closed)
  }

  /// Catches Don't Save that saves anyway, or does not close.
  func testDontSaveClosesWithoutSaving() async throws {
    let controller = try twoPanes()

    answer = .discard
    controller.dispatch(.close)
    await controller.pendingGuard?.value

    XCTAssertEqual(made[1].saves, 0)
    XCTAssertEqual(controller.paneIDs.count, 1)
  }

  /// Catches a window close that skips its panes' unsaved work. The red button asks, and Cancel
  /// keeps the window open.
  func testClosingTheWindowAsksAboutEveryPane() async throws {
    let controller = try twoPanes()
    made[0].unsavedWork = AppletUnsavedWork(label: "Untitled")
    let window = try XCTUnwrap(controller.window)

    answer = .cancel
    XCTAssertFalse(controller.windowShouldClose(window))
    await controller.pendingGuard?.value

    XCTAssertEqual(asked.last?.labels.sorted(), ["Untitled", "places.geojson"])
    XCTAssertEqual(controller.paneIDs.count, 2)
    XCTAssertFalse(made[0].closed)
    XCTAssertEqual(made[0].saves + made[1].saves, 0)
  }

  /// Catches a quit that loses unsaved work, or quits after a cancelled save. Quit asks once for
  /// every window, Save saves each pane, and a failed save stops the quit.
  func testQuitAsksOnceAndSavesEveryPane() async throws {
    let set = makeWindows()
    try set.open()
    try set.open()
    made[0].unsavedWork = AppletUnsavedWork(label: "a.geojson")
    made[1].unsavedWork = AppletUnsavedWork(label: "b.geojson")

    answer = .cancel
    let cancelled = await set.shouldQuit()
    XCTAssertFalse(cancelled)
    XCTAssertEqual(asked.last?.labels, ["a.geojson", "b.geojson"])

    answer = .save
    made[1].saveSucceeds = false
    let failed = await set.shouldQuit()
    XCTAssertFalse(failed)
    XCTAssertEqual(made[0].saves, 1)

    made[1].saveSucceeds = true
    let saved = await set.shouldQuit()
    XCTAssertTrue(saved)
    XCTAssertEqual(made[1].saves, 2)
  }

  /// Catches a quit that asks about unsaved work when there is none.
  func testQuitWithNothingUnsavedAsksNothing() async throws {
    let set = makeWindows()
    try set.open()

    let proceed = await set.shouldQuit()

    XCTAssertTrue(proceed)
    XCTAssertTrue(asked.isEmpty)
  }
}

/// A view that keeps its own undo stack, as a map does for its pin edits.
@MainActor
private final class UndoingView: NSView {
  let own = UndoManager()

  override var acceptsFirstResponder: Bool { true }
  override var undoManager: UndoManager? { own }
}

/// Edit > Undo reaches a focused view's own undo stack, and only that view's.
@MainActor
final class ViewUndoRoutingTests: XCTestCase {
  /// Catches an Undo that cannot reach a map's pin edits, or one that reaches past a view with no
  /// stack of its own into the window's.
  func testUndoReachesTheFocusedViewsOwnStack() throws {
    let window = MainWindow(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let view = UndoingView(frame: window.contentView!.bounds)
    window.contentView?.addSubview(view)
    var undone = 0
    view.own.registerUndo(withTarget: view) { _ in undone += 1 }
    view.own.setActionName("Move Pin")

    XCTAssertTrue(window.makeFirstResponder(view))

    let item = NSMenuItem(
      title: "Undo", action: #selector(MainWindow.undoEdit(_:)), keyEquivalent: "z")
    XCTAssertTrue(window.validateMenuItem(item))
    XCTAssertEqual(item.title, "Undo Move Pin")

    window.undoEdit(nil)
    XCTAssertEqual(undone, 1)

    let plain = NSView(frame: .zero)
    window.contentView?.addSubview(plain)
    window.makeFirstResponder(window.contentView)

    XCTAssertFalse(window.validateMenuItem(item))
    XCTAssertEqual(item.title, "Undo")
  }
}
