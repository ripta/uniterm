import AppKit
import AppletKit
import PaneModel
import Preferences
import XCTest

@testable import WindowKit

/// A pane view that records the presses it receives, as a terminal that reports the mouse would.
@MainActor
private final class PressRecorder: NSView {
  var presses = 0

  override func mouseDown(with event: NSEvent) {
    presses += 1
  }
}

/// A pane view that takes every key chord, as a terminal would take Control-K as input.
@MainActor
private final class KeyRecorder: NSView {
  var keysSeen = 0

  override var acceptsFirstResponder: Bool { true }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    keysSeen += 1
    return true
  }
}

/// The docked palette in a window with fake applets: where it sits, what it takes, and what its
/// overlay does. The live field editor, the real menu remap, and a real mouse-reporting terminal
/// need the app, so the UI tests cover them.
@MainActor
final class DockedPaletteTests: XCTestCase {
  private var fixtures: [WindowFixture] = []

  override func tearDown() async throws {
    for fixture in fixtures { fixture.cleanUp() }

    fixtures = []
  }

  private func makeFixture(
    mode: String? = "docked", edge: String? = nil, position: String? = nil
  ) throws -> WindowFixture {
    var stored: [String: String] = [:]
    if let mode { stored["paletteMode"] = mode }
    if let edge { stored["paletteDockEdge"] = edge }

    let fixture = try WindowFixture(storedPosition: position, stored: stored)
    fixtures.append(fixture)
    return fixture
  }

  private func palette(_ fixture: WindowFixture) -> CommandPaletteView {
    fixture.controller.contentController.commandPalette
  }

  private func strip(_ fixture: WindowFixture) -> NSView {
    fixture.controller.contentController.paletteStrip
  }

  private func frame(_ view: NSView, in fixture: WindowFixture) -> NSRect {
    view.convert(view.bounds, to: fixture.chrome)
  }

  private func type(_ text: String, _ fixture: WindowFixture) {
    palette(fixture).field.stringValue = text
    palette(fixture).controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
  }

  private func mouseDown(at point: NSPoint, _ fixture: WindowFixture) throws -> NSEvent {
    try XCTUnwrap(
      NSEvent.mouseEvent(
        with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
        windowNumber: fixture.controller.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
        clickCount: 1, pressure: 1))
  }

  private func controlK(_ fixture: WindowFixture) throws -> NSEvent {
    try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: .control, timestamp: 0,
        windowNumber: fixture.controller.window?.windowNumber ?? 0, context: nil,
        characters: "\u{0B}", charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40))
  }

  // MARK: Placement

  /// Catches a top-docked palette that sits below the title bar and costs the panes a row, or one
  /// that covers the traffic lights. It fills the title bar row, flush with the window's top edge,
  /// and its field stays clear of the window's sides.
  func testTheDockedPaletteSitsInTheTitleBarRowByDefault() throws {
    let fixture = try makeFixture(position: "bottom")
    let safe = fixture.chrome.safeAreaRect
    let strip = frame(strip(fixture), in: fixture)
    let field = frame(palette(fixture), in: fixture)
    let inset = MainContentViewController.titleBarPaletteSideInset

    XCTAssertEqual(fixture.controller.contentController.palettePlacement.edge, .top)
    XCTAssertNil(fixture.controller.contentController.edge(of: .commandPalette))
    XCTAssertGreaterThan(fixture.chrome.bounds.maxY, safe.maxY, "the window has a title bar row")
    XCTAssertEqual(strip.maxY, fixture.chrome.bounds.maxY)
    XCTAssertEqual(strip.minY, safe.maxY)
    XCTAssertEqual(fixture.paneArea.frame.maxY, safe.maxY, "the panes keep the whole safe area")
    XCTAssertEqual(field.midY, strip.midY, accuracy: 0.5)
    XCTAssertEqual(field.height, CommandPaletteView.Style.titleBar.height)
    XCTAssertGreaterThanOrEqual(field.minX, inset - 0.5)
    XCTAssertLessThanOrEqual(field.maxX, fixture.chrome.bounds.maxX - inset + 0.5)
    XCTAssertFalse(palette(fixture).isHidden)
  }

  func testTheDockedPaletteCanSitAtTheBottom() throws {
    let fixture = try makeFixture(edge: "bottom", position: "top")
    let safe = fixture.chrome.safeAreaRect

    XCTAssertEqual(fixture.controller.contentController.edge(of: .commandPalette), .bottom)
    XCTAssertEqual(frame(strip(fixture), in: fixture).minY, safe.minY)
    XCTAssertEqual(fixture.paneArea.frame.minY, frame(strip(fixture), in: fixture).maxY)
  }

  /// Catches the stacking order flipping. At the bottom, the bar is at the window's edge and the
  /// palette is next to the panes. At the top, the palette is in the title bar row and the bar
  /// sits right below it.
  func testOnOneEdgeTheStatusBarAndThePaletteStackInOrder() throws {
    for edge in ["top", "bottom"] {
      let fixture = try makeFixture(edge: edge, position: edge)
      let bar = fixture.bar.frame
      let strip = frame(strip(fixture), in: fixture)
      let panes = fixture.paneArea.frame

      if edge == "top" {
        XCTAssertEqual(bar.maxY, strip.minY, "the bar is below the title bar row")
        XCTAssertEqual(bar.minY, panes.maxY)
      } else {
        XCTAssertLessThan(bar.maxY, strip.maxY)
        XCTAssertEqual(strip.maxY, panes.minY)
        XCTAssertEqual(bar.maxY, strip.minY)
      }
    }
  }

  /// Catches a bottom strip that is missing from the minimum size, so a window could shrink until
  /// the strip overlaps the panes. A top-docked palette lives in the title bar row and adds nothing.
  func testTheBottomStripCountsTowardTheMinimumSize() throws {
    let top = try makeFixture()
    let docked = try makeFixture(edge: "bottom")
    let floating = try makeFixture(mode: nil)

    let dockedHeight = try XCTUnwrap(docked.controller.window?.contentMinSize.height)
    let floatingHeight = try XCTUnwrap(floating.controller.window?.contentMinSize.height)

    let topHeight = try XCTUnwrap(top.controller.window?.contentMinSize.height)

    XCTAssertEqual(
      dockedHeight - floatingHeight, MainContentViewController.dockedPaletteThickness,
      accuracy: 0.5)
    XCTAssertEqual(topHeight, floatingHeight, accuracy: 0.5)
  }

  /// Catches a floating palette that still holds a row, or a docked one that leaves a ghost.
  func testSwitchingToFloatingGivesTheRowBackAndHidesThePalette() async throws {
    let fixture = try makeFixture()
    fixture.store.set(.floating, for: .paletteMode)

    let switched = await waitUntil {
      fixture.controller.contentController.palettePlacement.mode == .floating
    }

    XCTAssertTrue(switched)
    XCTAssertTrue(palette(fixture).isHidden)
    XCTAssertNil(strip(fixture).superview)
  }

  func testChangingTheEdgeMovesTheStripLive() async throws {
    let fixture = try makeFixture()
    fixture.store.set(.bottom, for: .paletteDockEdge)

    let moved = await waitUntil {
      fixture.controller.contentController.edge(of: .commandPalette) == .bottom
    }

    XCTAssertTrue(moved)
  }

  /// Catches an invalid stored value that is accepted, rewritten, or silent.
  func testInvalidValuesFallBackAndWarnOnce() async throws {
    let fixture = try makeFixture(mode: "sideways", edge: "left")

    XCTAssertEqual(fixture.controller.contentController.palettePlacement.mode, .floating)
    XCTAssertEqual(fixture.controller.contentController.palettePlacement.edge, .top)
    XCTAssertTrue(palette(fixture).isHidden)
    XCTAssertEqual(fixture.defaults.string(forKey: "paletteMode"), "sideways")

    let texts = fixture.center.history.map(\.text)

    XCTAssertEqual(texts.filter { $0.contains("palette mode") }.count, 1)
    XCTAssertEqual(texts.filter { $0.contains("palette edge") }.count, 1)
    XCTAssertTrue(
      texts.contains { $0.contains("\u{201C}sideways\u{201D}") && $0.contains("floating") })
  }

  // MARK: Focus

  /// Catches a docked palette that grabs the keyboard when the window opens, or when the key view
  /// loop reaches it.
  func testAnInactiveDockedPaletteTakesNoKeyboard() throws {
    let fixture = try makeFixture()
    let window = try XCTUnwrap(fixture.controller.window)

    let field = palette(fixture).field

    XCTAssertFalse(field.acceptsFirstResponder)

    window.makeFirstResponder(field)

    XCTAssertNil(field.currentEditor(), "the field never began editing")
    XCTAssertFalse(window.firstResponder === field)
    XCTAssertFalse(fixture.controller.isPaletteVisible)
  }

  /// Catches an inactive docked palette that takes Control-K, which only an open palette binds, or
  /// an active one that does not fill in the kind keyword.
  func testControlKFillsInTheKindKeywordOnlyWhileTheDockedPaletteIsActive() throws {
    let fixture = try makeFixture()
    let controller = fixture.controller
    let window = try XCTUnwrap(controller.window)
    let applet = try XCTUnwrap(controller.paneArea.applet(for: controller.focusedPane))
    let catcher = KeyRecorder()
    applet.view.addSubview(catcher)
    XCTAssertTrue(window.makeFirstResponder(catcher))

    XCTAssertTrue(window.performKeyEquivalent(with: try controlK(fixture)))
    XCTAssertEqual(catcher.keysSeen, 1, "an inactive docked palette took Control-K")
    XCTAssertEqual(palette(fixture).query, "")

    controller.dispatch(.showCommandPalette)

    XCTAssertTrue(window.performKeyEquivalent(with: try controlK(fixture)))
    XCTAssertEqual(catcher.keysSeen, 1)
    XCTAssertEqual(palette(fixture).query, "kind:")
  }

  /// Catches a click that does not activate, or one that activates without the keyboard.
  func testClickingAnInactiveDockedPaletteActivatesIt() throws {
    let fixture = try makeFixture()
    let window = try XCTUnwrap(fixture.controller.window)
    let field = palette(fixture).field

    let point = field.convert(NSPoint(x: 10, y: 10), to: nil)
    field.mouseDown(with: try mouseDown(at: point, fixture))

    XCTAssertTrue(fixture.controller.isPaletteVisible)
    XCTAssertTrue(window.firstResponder === field.currentEditor())
    XCTAssertFalse(fixture.controller.paletteWillHandleMouseDown(try mouseDown(at: point, fixture)))
  }

  /// Catches a toggle that leaves the field holding the keyboard, or loses the prior pane.
  func testTheHotkeyOnAnActiveDockedPaletteUnfocusesItAndReturnsToThePane() throws {
    let fixture = try makeFixture()
    let controller = fixture.controller
    let window = try XCTUnwrap(controller.window)
    let pane = controller.focusedPane
    let applet = try XCTUnwrap(controller.paneArea.applet(for: pane) as? FakeApplet)

    controller.dispatch(.showCommandPalette)
    XCTAssertTrue(controller.isPaletteVisible)
    XCTAssertEqual(controller.paletteTarget, pane)

    let before = applet.focusCount
    controller.dispatch(.showCommandPalette)

    XCTAssertFalse(controller.isPaletteVisible)
    XCTAssertFalse(window.firstResponder === palette(fixture).field.currentEditor())
    XCTAssertFalse(palette(fixture).isHidden, "a docked palette stays on show")
    XCTAssertEqual(applet.focusCount, before + 1)
    XCTAssertEqual(palette(fixture).query, "")
  }

  /// Defines what a settings change does to an active palette. It deactivates and the keyboard goes
  /// back to the pane, so the field never holds a keyboard it was moved out from under.
  func testSwitchingModeWhileActiveDeactivatesAndFocusesThePane() async throws {
    let fixture = try makeFixture()
    let controller = fixture.controller
    let applet = try XCTUnwrap(
      controller.paneArea.applet(for: controller.focusedPane) as? FakeApplet)

    controller.showCommandPalette()
    let before = applet.focusCount
    fixture.store.set(.floating, for: .paletteMode)

    let switched = await waitUntil { !controller.isPaletteVisible }

    XCTAssertTrue(switched)
    XCTAssertEqual(applet.focusCount, before + 1)
    XCTAssertTrue(palette(fixture).isHidden)
  }

  // MARK: Overlay

  /// Catches an activation that resizes the content area or a pane, which would reflow every
  /// terminal.
  func testActivatingDoesNotResizeTheContentAreaOrAPane() throws {
    let fixture = try makeFixture()
    let controller = fixture.controller
    let second = try XCTUnwrap(controller.openPane(.terminalShell, axis: .row))
    fixture.layout()

    let paneFrames = controller.paneIDs.map { fixture.paneArea.paneView(for: $0)?.frame }
    let area = fixture.paneArea.frame
    let strip = frame(strip(fixture), in: fixture)

    controller.showCommandPalette()
    type("", fixture)
    fixture.layout()

    XCTAssertEqual(fixture.paneArea.frame, area)
    XCTAssertEqual(frame(self.strip(fixture), in: fixture), strip)
    XCTAssertEqual(controller.paneIDs.map { fixture.paneArea.paneView(for: $0)?.frame }, paneFrames)
    XCTAssertTrue(controller.paneIDs.contains(second))
    XCTAssertFalse(palette(fixture).results.isHidden)
  }

  /// Catches an overlay that spills out of the pane area, or opens toward the docked edge.
  func testTheOverlayStaysInTheContentAreaAndGrowsAwayFromTheEdge() throws {
    for edge in ["top", "bottom"] {
      let fixture = try makeFixture(edge: edge)
      fixture.controller.showCommandPalette()
      fixture.layout()

      let results = frame(palette(fixture).results, in: fixture)
      let field = frame(palette(fixture), in: fixture)
      let area = fixture.paneArea.frame

      XCTAssertGreaterThan(results.height, 0)
      XCTAssertGreaterThanOrEqual(results.minY, area.minY, edge)
      XCTAssertLessThanOrEqual(results.maxY, area.maxY, edge)
      XCTAssertEqual(results.minX, field.minX, accuracy: 0.5)
      XCTAssertEqual(results.width, field.width, accuracy: 0.5)

      if edge == "top" {
        XCTAssertLessThan(results.maxY, field.minY + 0.5, "grows down")
      } else {
        XCTAssertGreaterThan(results.minY, field.maxY - 0.5, "grows up")
      }
    }
  }

  /// Catches an overlay drawn under the panes or the strip, including after the strip is
  /// installed later by a settings change.
  func testTheOverlayDrawsAboveEveryOtherView() async throws {
    for mode in ["docked", "floating"] {
      let fixture = try makeFixture(mode: mode)

      XCTAssertTrue(fixture.chrome.subviews.last === palette(fixture).results, mode)
    }

    let fixture = try makeFixture(mode: nil)
    fixture.store.set(.docked, for: .paletteMode)

    let docked = await waitUntil {
      fixture.controller.contentController.palettePlacement.mode == .docked
    }

    XCTAssertTrue(docked)
    XCTAssertTrue(fixture.chrome.subviews.last === palette(fixture).results)
  }

  /// Catches an overlay that is taller than a short content area.
  func testAShortWindowShortensTheOverlay() throws {
    let fixture = try makeFixture()
    let window = try XCTUnwrap(fixture.controller.window)

    window.setContentSize(NSSize(width: 960, height: window.contentMinSize.height + 60))
    fixture.controller.showCommandPalette()
    fixture.layout()

    let results = frame(palette(fixture).results, in: fixture)
    XCTAssertLessThanOrEqual(results.maxY, fixture.paneArea.frame.maxY + 0.5)
    XCTAssertGreaterThanOrEqual(results.minY, fixture.paneArea.frame.minY - 0.5)
  }

  // MARK: Search

  /// Catches a docked palette that ranks or filters differently from the floating one.
  func testDockedAndFloatingListTheSameEntriesForTheSameQuery() throws {
    let docked = try makeFixture()
    let floating = try makeFixture(mode: nil)

    for fixture in [docked, floating] {
      fixture.controller.showCommandPalette()
    }

    XCTAssertEqual(
      palette(docked).entries.map(\.title), palette(floating).entries.map(\.title))

    for fixture in [docked, floating] { type("split", fixture) }

    XCTAssertEqual(
      palette(docked).entries.map(\.title), palette(floating).entries.map(\.title))
    XCTAssertEqual(palette(docked).selection, palette(floating).selection)
  }

  /// Catches an overlay whose empty-query order was fixed when the window opened.
  func testTheEmptyQueryOrderReflectsRecencyAtActivation() throws {
    let fixture = try makeFixture()
    let controller = fixture.controller
    let first = controller.focusedPane
    let second = try XCTUnwrap(controller.openPane(.terminalShell, axis: .row))

    controller.paneArea.focus(first, keyboard: false)
    controller.showCommandPalette()
    XCTAssertEqual(palette(fixture).selection, .tab(pane: second, tab: try tabID(second, fixture)))
    controller.hideCommandPalette(restoringFocus: true)

    controller.paneArea.focus(second, keyboard: false)
    controller.showCommandPalette()
    XCTAssertEqual(palette(fixture).selection, .tab(pane: first, tab: try tabID(first, fixture)))
  }

  private func tabID(_ pane: NodeID, _ fixture: WindowFixture) throws -> AppletTabID {
    let applet = try XCTUnwrap(fixture.controller.paneArea.applet(for: pane) as? FakeApplet)
    return applet.tabID(0)
  }

  // MARK: Placeholder

  /// Catches a placeholder that does not name the key, or names a stale one after a remap.
  func testThePlaceholderNamesTheMenuItemsCurrentKey() throws {
    let saved = NSApp.mainMenu
    defer { NSApp.mainMenu = saved }

    let fixture = try makeFixture()
    let commandMenu = CommandMenu(
      registry: fixture.controller.commands, activeController: { fixture.controller })
    commandMenu.install()
    let item = try XCTUnwrap(
      commandMenu.menu.items[3].submenu?.items.first {
        ($0 as? CommandMenuItem)?.commandID == .showCommandPalette
      })

    fixture.controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
    let field = palette(fixture).field

    XCTAssertEqual(field.placeholderString, "Search tabs and commands (\u{2318}K)")

    item.keyEquivalent = "o"
    fixture.controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))

    XCTAssertEqual(field.placeholderString, "Search tabs and commands (\u{2318}O)")

    fixture.controller.showCommandPalette()
    XCTAssertEqual(field.placeholderString, "Search tabs and commands")
  }

  // MARK: Mouse

  /// Catches a click on something that cannot take focus, such as the status bar, that leaves the
  /// keyboard nowhere.
  func testAClickOnTheStatusBarReturnsTheKeyboardToThePriorPane() throws {
    let fixture = try makeFixture()
    let controller = fixture.controller
    let window = try XCTUnwrap(controller.window)
    let applet = try XCTUnwrap(
      controller.paneArea.applet(for: controller.focusedPane) as? FakeApplet)

    controller.showCommandPalette()
    let before = applet.focusCount

    let point = fixture.bar.convert(NSPoint(x: 4, y: 4), to: nil)
    let event = try mouseDown(at: point, fixture)

    XCTAssertTrue(controller.paletteWillHandleMouseDown(event))
    XCTAssertFalse(controller.isPaletteVisible)

    window.makeFirstResponder(nil)
    controller.paletteDidHandleMouseDown()

    XCTAssertEqual(applet.focusCount, before + 1)
  }

  /// Defines the deactivating click. The palette steps aside before the press is dispatched, so the
  /// press lands on the view under it and a terminal that reports the mouse sees it. That the
  /// window then dispatches the press needs a live event loop, so a UI test covers it with a real
  /// terminal.
  func testTheDeactivatingClickLeavesTheViewUnderItToReceiveThePress() throws {
    let fixture = try makeFixture()
    let controller = fixture.controller
    let window = try XCTUnwrap(controller.window)
    let applet = try XCTUnwrap(
      controller.paneArea.applet(for: controller.focusedPane) as? FakeApplet)

    let recorder = PressRecorder()
    applet.view.addSubview(recorder)
    fixture.layout()
    recorder.frame = applet.view.bounds

    controller.showCommandPalette()

    let point = recorder.convert(NSPoint(x: 20, y: 20), to: nil)
    let event = try mouseDown(at: point, fixture)

    XCTAssertTrue(controller.paletteWillHandleMouseDown(event), "the press deactivates")
    XCTAssertFalse(controller.isPaletteVisible)

    let hit = window.contentView?.hitTest(
      try XCTUnwrap(window.contentView).convert(point, from: nil))
    XCTAssertTrue(hit === recorder)

    hit?.mouseDown(with: event)
    XCTAssertEqual(recorder.presses, 1)
  }
}
