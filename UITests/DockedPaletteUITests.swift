import XCTest

/// Drives the docked command palette in the launched app. Each test proves a contract that only
/// the real window, the field editor, the menu, and a live terminal can show.
@MainActor
final class DockedPaletteUITests: UnitermUITestCase {
  private let docked = ["paletteMode": "docked"]

  private func field(in app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any)["command-palette-field"]
  }

  private func results(in app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any)["command-palette-results"]
  }

  private func activate(in app: XCUIApplication) {
    app.typeKey("k", modifierFlags: .command)
    XCTAssertTrue(results(in: app).appears(timeout: 5), "the overlay never showed")
  }

  /// Catches a docked palette that grabs the keyboard before it is activated, a placeholder that
  /// does not name the key, and a toggle that leaves the keyboard in the field. The terminal must
  /// receive the keys typed while the palette is inactive and after it is deactivated.
  func testADockedPaletteTakesNoKeyboardUntilTheHotkeyAndGivesItBack() {
    let app = launchApp(settings: docked)
    let terminal = waitForTerminal(in: app)

    XCTAssertTrue(field(in: app).exists, "a docked palette is always on show")
    XCTAssertEqual(
      field(in: app).placeholderValue, "Search tabs and commands (\u{2318}K)")
    XCTAssertFalse(results(in: app).exists)

    app.typeText("echo typed-while-inactive\n")
    XCTAssertTrue(
      waitFor(terminal, timeout: 20) { $0.contains("typed-while-inactive") },
      "the inactive palette took the keyboard")

    activate(in: app)
    app.typeText("split")
    XCTAssertTrue(waitFor(field(in: app), timeout: 5) { $0 == "split" })

    app.typeKey("k", modifierFlags: .command)
    XCTAssertTrue(waitUntilGone(results(in: app)), "the hotkey did not deactivate the palette")
    XCTAssertTrue(field(in: app).exists)

    app.typeText("echo back-in-the-terminal\n")
    XCTAssertTrue(
      waitFor(terminal, timeout: 20) { $0.contains("back-in-the-terminal") },
      "the keyboard did not return to the pane")
  }

  /// Catches a click that does not activate an inactive docked palette, and an activation that
  /// resizes the terminal and so reflows it.
  func testClickingTheDockedPaletteActivatesItWithoutResizingTheTerminal() {
    let app = launchApp(settings: docked)
    let terminal = waitForTerminal(in: app)
    let before = terminal.frame

    field(in: app).click()

    XCTAssertTrue(results(in: app).appears(timeout: 5), "the click did not activate")
    app.typeText("split")
    XCTAssertTrue(waitFor(field(in: app), timeout: 5) { $0 == "split" })
    XCTAssertEqual(terminal.frame, before, "activation resized the terminal")

    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(waitUntilGone(results(in: app)))
    XCTAssertEqual(terminal.frame, before, "deactivation resized the terminal")
  }

  /// Defines the deactivating click: it also reaches the terminal under it. The shell turns on
  /// mouse reporting and echoes what it reads with no line buffering, so a press that arrives shows as a report.
  func testTheDeactivatingClickReachesAMouseReportingTerminal() {
    let app = launchApp(settings: docked)
    let terminal = waitForTerminal(in: app)

    app.typeText("stty -icanon -echo; printf \"\\033[?1000h\\033[?1006h\"; cat -v\n")
    XCTAssertTrue(waitFor(terminal, timeout: 20) { $0.contains("cat -v") })

    field(in: app).click()
    XCTAssertTrue(results(in: app).appears(timeout: 5))

    terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).click()

    XCTAssertTrue(waitUntilGone(results(in: app)), "the click did not deactivate the palette")
    XCTAssertTrue(
      waitFor(terminal, timeout: 20) { $0.contains("^[[<0;") },
      "the deactivating click never reached the terminal")
  }

  /// Catches a click on something that takes no keyboard, which would leave the keys going nowhere.
  func testAClickOnTheStatusBarReturnsTheKeyboardToThePane() {
    let app = launchApp(settings: docked)
    let terminal = waitForTerminal(in: app)

    activate(in: app)
    app.descendants(matching: .any)["status-bar"].click()

    XCTAssertTrue(waitUntilGone(results(in: app)))
    app.typeText("echo after-bar-click\n")
    XCTAssertTrue(
      waitFor(terminal, timeout: 20) { $0.contains("after-bar-click") },
      "the keyboard did not return to the pane")
  }

  /// Catches a placeholder that keeps naming the default key after a user's App Shortcuts remap.
  func testThePlaceholderNamesARemappedKey() {
    let app = launchApp(
      arguments: ["-NSUserKeyEquivalents", #"{"Show Command Palette"="@$o";}"#], settings: docked)
    _ = waitForTerminal(in: app)

    XCTAssertEqual(
      field(in: app).placeholderValue, "Search tabs and commands (\u{21E7}\u{2318}O)")

    app.typeKey("o", modifierFlags: [.command, .shift])
    XCTAssertTrue(results(in: app).appears(timeout: 5), "the remapped key did not work")
  }

  /// Catches a top-docked palette that sits below the title bar or covers the traffic lights, and
  /// a bottom-docked overlay that opens toward the edge instead of away from it.
  func testTheTopStripSitsInTheTitleBarRowAndTheOverlayOpensAwayFromTheEdge() {
    let top = launchApp(settings: docked)
    _ = waitForTerminal(in: top)

    // The traffic lights end about 70 points from the window's left edge. The title bar row is
    // under 40 points tall.
    let window = mainWindow(in: top).frame
    let palette = field(in: top).frame

    XCTAssertLessThan(palette.maxY, window.minY + 40, "the palette sits below the title bar row")
    XCTAssertGreaterThan(palette.minX, window.minX + 70, "the palette covers the traffic lights")

    activate(in: top)
    XCTAssertGreaterThanOrEqual(results(in: top).frame.minY, palette.maxY)
    top.terminate()

    let bottom = launchApp(settings: ["paletteMode": "docked", "paletteDockEdge": "bottom"])
    _ = waitForTerminal(in: bottom)

    activate(in: bottom)
    XCTAssertLessThanOrEqual(results(in: bottom).frame.maxY, field(in: bottom).frame.minY)
  }

  /// Catches a Settings row that does not reach the window live, in either direction.
  func testTheSettingsWindowSwitchesTheModeLive() {
    let app = launchApp()
    _ = waitForTerminal(in: app)
    XCTAssertFalse(field(in: app).exists, "a floating palette is hidden")

    app.typeKey(",", modifierFlags: .command)
    let settings = app.windows["settings-window"]
    XCTAssertTrue(settings.appears(timeout: 5))

    settings.radioGroups["palette-mode-control"].radioButtons["Docked"].click()
    settings.radioGroups["palette-dock-edge-control"].radioButtons["Bottom"].click()
    app.typeKey("w", modifierFlags: .command)
    XCTAssertTrue(waitUntilGone(settings, timeout: 5))

    XCTAssertTrue(field(in: app).appears(timeout: 5), "the palette did not dock")
    XCTAssertGreaterThan(
      field(in: app).frame.minY, mainWindow(in: app).frame.midY, "the palette did not move down")
  }
}
