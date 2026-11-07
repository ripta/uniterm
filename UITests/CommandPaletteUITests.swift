import XCTest

/// Drives the command palette in the launched app. Each test proves a contract that only AppKit's
/// key routing, the real menu, and the field editor can show.
///
/// The App Shortcuts remaps use the `-NSUserKeyEquivalents` launch argument. It lands in the app's
/// argument domain, which AppKit reads for menu items the way it reads a remap saved in System
/// Settings.
@MainActor
final class CommandPaletteUITests: UnitermUITestCase {
  private func palette(in app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any)["command-palette"]
  }

  private func field(in app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any)["command-palette-field"]
  }

  private func tab(_ index: Int, in app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any)["tab-\(index)"]
  }

  private func showPalette(
    in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line
  ) {
    app.typeKey("k", modifierFlags: .command)
    XCTAssertTrue(
      palette(in: app).waitForExistence(timeout: 5), "the palette never showed", file: file,
      line: line)
  }

  /// Catches a Cmd-K that a focused terminal takes, a palette that does not hide on the
  /// same key, and an Escape that leaves the keyboard in the palette. Keys typed after the hide
  /// must reach the terminal.
  func testTheHotkeyTogglesThePaletteAndEscapeReturnsTheKeyboardToTheTerminal() {
    let app = launchApp()
    let terminal = waitForTerminal(in: app)

    showPalette(in: app)

    app.typeKey("k", modifierFlags: .command)
    XCTAssertTrue(waitUntilGone(palette(in: app)), "the toggle did not hide the palette")

    showPalette(in: app)
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(waitUntilGone(palette(in: app)), "Escape did not hide the palette")

    app.typeText("echo back-in-terminal\n")
    XCTAssertTrue(
      waitFor(terminal, timeout: 20) { $0.contains("back-in-terminal") },
      "the terminal did not get the keyboard back")
  }

  /// Catches a palette command that does not run on Enter.
  func testTypingFiltersAndEnterRunsTheCommand() {
    let app = launchApp()
    _ = waitForTerminal(in: app)

    showPalette(in: app)
    app.typeText("split right")
    app.typeKey(.return, modifierFlags: [])

    XCTAssertTrue(waitUntilGone(palette(in: app)))
    XCTAssertTrue(
      launcher(in: mainWindow(in: app)).waitForExistence(timeout: 5),
      "Split Right did not open a pane")
  }

  /// Catches Cmd-W that closes the pane, and so the window, while the field has focus.
  func testCommandWInTheFieldDismissesAndClosesNothing() {
    let app = launchApp()
    _ = waitForTerminal(in: app)

    showPalette(in: app)
    app.typeKey("w", modifierFlags: .command)

    XCTAssertTrue(waitUntilGone(palette(in: app)))
    XCTAssertTrue(mainWindow(in: app).exists, "Cmd-W closed the window")
    XCTAssertTrue(mainWindow(in: app).textViews["terminal"].exists)
  }

  /// Catches Cmd-V and Cmd-Z that reach the pane or the window and not the field.
  func testPasteAndUndoEditTheField() {
    let app = launchApp()
    _ = waitForTerminal(in: app)

    showPalette(in: app)
    app.typeText("ab")
    app.typeKey("a", modifierFlags: .command)
    app.typeKey("c", modifierFlags: .command)
    app.typeKey(.rightArrow, modifierFlags: [])
    app.typeKey("v", modifierFlags: .command)

    XCTAssertTrue(
      waitFor(field(in: app), timeout: 5) { $0 == "abab" }, "Cmd-V did not paste into the field")

    app.typeKey("z", modifierFlags: .command)

    XCTAssertTrue(
      waitFor(field(in: app), timeout: 5) { $0 == "ab" },
      "Cmd-Z did not undo the field's edit, value: \(String(describing: field(in: app).value))")
    XCTAssertTrue(palette(in: app).exists)
    XCTAssertTrue(mainWindow(in: app).textViews["terminal"].exists)
  }

  /// Catches a binding that runs while the palette holds the keyboard, or runs on the field. Cmd-T
  /// hides the palette and then opens the tab in the terminal.
  func testCommandTAfterDismissOpensATabInThePriorPane() {
    let app = launchApp()
    _ = waitForTerminal(in: app)

    showPalette(in: app)
    app.typeKey("t", modifierFlags: .command)

    XCTAssertTrue(waitUntilGone(palette(in: app)))
    XCTAssertTrue(tab(1, in: app).waitForExistence(timeout: 10), "Cmd-T did not open a tab")
  }

  /// Catches File > Close that takes another path than Cmd-W. With two tabs it closes the
  /// selected one. With the palette up it only dismisses it, as Cmd-W does.
  func testTheCloseMenuItemRunsTheCommandCommandWRuns() {
    let app = launchApp()
    _ = waitForTerminal(in: app)

    app.typeKey("t", modifierFlags: .command)
    XCTAssertTrue(tab(1, in: app).waitForExistence(timeout: 10))
    XCTAssertTrue(
      waitFor(mainWindow(in: app).textViews["terminal"], timeout: 40) { $0.contains("% ") })

    showPalette(in: app)
    app.menuBars.menuItems["Close"].click()

    XCTAssertTrue(waitUntilGone(palette(in: app)))
    XCTAssertTrue(tab(1, in: app).exists, "the menu item closed a tab with the palette up")

    app.menuBars.menuItems["Close"].click()
    XCTAssertTrue(waitUntilGone(tab(1, in: app), timeout: 15), "File > Close did not close the tab")
  }

  /// Catches a remap that loses to the default binding of another item. Cmd-T is New Tab, and the
  /// remapped palette item must win even with the terminal focused.
  func testARemapOntoAnotherBindingWins() {
    let app = launchApp(arguments: ["-NSUserKeyEquivalents", #"{"Show Command Palette"="@t";}"#])
    _ = waitForTerminal(in: app)

    app.typeKey("t", modifierFlags: .command)

    XCTAssertTrue(palette(in: app).waitForExistence(timeout: 5), "the remapped key did not win")
    XCTAssertFalse(tab(1, in: app).exists, "New Tab ran instead")
  }

  /// Catches a remap onto a Control chord that the terminal would take as input.
  func testARemapOntoAControlChordReachesUnitermBeforeTheTerminal() {
    let app = launchApp(arguments: ["-NSUserKeyEquivalents", #"{"Show Command Palette"="^g";}"#])
    _ = waitForTerminal(in: app)

    app.typeKey("g", modifierFlags: .control)

    XCTAssertTrue(palette(in: app).waitForExistence(timeout: 5), "the terminal took the key")
  }

  // MARK: Tab search

  private func row(_ title: String, kind: String = "Terminal", in app: XCUIApplication)
    -> XCUIElement
  {
    app.descendants(matching: .any).matching(identifier: "command-palette-row")
      .element(
        matching: NSPredicate(format: "label == %@ AND value BEGINSWITH %@", title, kind))
  }

  /// Opens a tab and waits for its shell to show a prompt.
  private func openTab(in app: XCUIApplication) {
    app.typeKey("t", modifierFlags: .command)

    let terminal = mainWindow(in: app).textViews["terminal"]
    XCTAssertTrue(terminal.waitForExistence(timeout: 15))
    XCTAssertTrue(
      waitFor(terminal, timeout: 40) { $0.contains("% ") }, "the new tab never showed a prompt")
  }

  /// Catches a tab list that misses a background tab, a choice that switches the tab but leaves
  /// the keyboard elsewhere, and a row that does not say it is a tab. The first tab sets its title
  /// and then waits, so its prompt cannot reset the title. After the choice, Control-C ends the
  /// wait and the next line must reach that tab's shell.
  func testChoosingABackgroundTabSelectsItAndTheKeyboardFollows() {
    let app = launchApp()
    _ = waitForTerminal(in: app)

    app.typeText("printf \"\\033]0;zzq-title\\007\"; sleep 600\n")
    openTab(in: app)
    XCTAssertTrue(tab(1, in: app).waitForExistence(timeout: 10))

    showPalette(in: app)
    app.typeText("zzq")

    let entry = row("zzq-title", in: app)
    XCTAssertTrue(entry.waitForExistence(timeout: 10), "the background tab was not listed")
    XCTAssertEqual(entry.value as? String, "Terminal, enabled")

    app.typeKey(.return, modifierFlags: [])

    XCTAssertTrue(waitUntilGone(palette(in: app)))
    XCTAssertTrue(
      waitFor(tab(0, in: app), timeout: 10) { $0 == "selected" }, "the tab was not selected")

    app.typeKey("c", modifierFlags: .control)
    app.typeText("echo reached-first-tab\n")
    XCTAssertTrue(
      waitFor(mainWindow(in: app).textViews["terminal"], timeout: 20) {
        $0.contains("reached-first-tab")
      }, "the keyboard did not follow the chosen tab")
  }

  /// Catches a title that reaches a row with its control and bidi characters, so a program could
  /// pose as a command or reorder the text. The title carries an override and an escape.
  func testAProgramTitleShowsNeutralizedAsATab() {
    let app = launchApp()
    _ = waitForTerminal(in: app)

    app.typeText("printf \"\\033]0;New\\342\\200\\256 Window\\007\"; sleep 600\n")
    openTab(in: app)

    showPalette(in: app)
    app.typeText("new w")

    let entry = row("New Window", in: app)
    XCTAssertTrue(entry.waitForExistence(timeout: 10), "the title was not neutralized")
    XCTAssertEqual(entry.value as? String, "Terminal, enabled")
    XCTAssertTrue(
      row("New Window", kind: "Command", in: app).exists,
      "the command and the tab of the same name are not told apart")
  }

  /// Catches a list that stays stale in the open palette. The second tab titles itself and exits
  /// after a few seconds. The row shows while the palette is up and must go once the tab closes.
  func testATabThatClosesWhileThePaletteShowsDisappearsFromTheList() {
    let app = launchApp()
    _ = waitForTerminal(in: app)

    openTab(in: app)
    app.typeText("printf \"\\033]0;yyq-title\\007\"; sleep 8; exit\n")
    app.typeKey("1", modifierFlags: .command)
    XCTAssertTrue(waitFor(tab(0, in: app), timeout: 10) { $0 == "selected" })

    showPalette(in: app)
    app.typeText("yyq")
    XCTAssertTrue(row("yyq-title", in: app).waitForExistence(timeout: 10))

    XCTAssertTrue(
      waitUntilGone(row("yyq-title", in: app), timeout: 30),
      "the closed tab stayed in the open palette")
    XCTAssertTrue(palette(in: app).exists)
  }
}
