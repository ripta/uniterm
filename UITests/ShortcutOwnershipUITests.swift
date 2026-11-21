import XCTest

/// Drives who owns a shortcut in the launched app. Each test proves a contract that only AppKit's
/// key routing, the real menu, and App Shortcuts remaps can show.
///
/// A remap uses the `-NSUserKeyEquivalents` launch argument, which lands in the app's argument
/// domain the way a remap saved in System Settings does.
@MainActor
final class ShortcutOwnershipUITests: UnitermUITestCase {
  private func palette(in app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any)["command-palette"]
  }

  private func tab(_ index: Int, in app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any)["tab-\(index)"]
  }

  private func message(in app: XCUIApplication) -> XCUIElement {
    mainWindow(in: app).staticTexts["status-message"]
  }

  /// Catches a terminal command that sits in uniterm's menus. Close is File > Close whatever the tab
  /// count, text size is in View, New Tab is in File, and Clear Screen has the terminal's menu.
  func testTerminalCommandsSitInTheirHomes() {
    let app = launchApp()
    _ = waitForTerminal(in: app)
    let bar = app.menuBars

    XCTAssertTrue(bar.menuBarItems["Terminal"].exists, "no terminal menu")

    bar.menuBarItems["File"].click()
    XCTAssertTrue(bar.menuItems["Close"].exists)
    XCTAssertFalse(bar.menuItems["Close Pane"].exists)
    XCTAssertTrue(bar.menuItems["New Tab"].exists)
    app.typeKey(.escape, modifierFlags: [])

    func items(of menu: String) -> XCUIElementQuery {
      bar.menuBarItems[menu].menus.menuItems
    }

    bar.menuBarItems["View"].click()
    XCTAssertTrue(items(of: "View")["Bigger Text"].exists)
    XCTAssertFalse(items(of: "View")["Clear Screen"].exists, "Clear Screen is in View")
    app.typeKey(.escape, modifierFlags: [])

    bar.menuBarItems["Terminal"].click()
    XCTAssertTrue(items(of: "Terminal")["Clear Screen"].exists)
    app.typeKey(.escape, modifierFlags: [])

    bar.menuBarItems["Edit"].click()
    XCTAssertTrue(items(of: "Edit")["Cut"].exists)
    XCTAssertTrue(items(of: "Edit")["Redo"].exists)
    app.typeKey(.escape, modifierFlags: [])
  }

  /// Catches an applet menu that shows while a pane that is not that applet has focus. The launcher
  /// has no terminal items.
  func testTheTerminalMenuIsGoneWhileTheLauncherHasFocus() {
    let app = launchApp()
    let window = mainWindow(in: app)
    _ = waitForTerminal(in: app)

    app.typeKey("d", modifierFlags: .command)
    XCTAssertTrue(launcher(in: window).appears(timeout: 5))

    XCTAssertFalse(app.menuBars.menuBarItems["Terminal"].exists, "the terminal menu stayed")
  }

  /// Catches Cmd-W that closes the pane while the terminal has two tabs. The first Cmd-W closes the
  /// tab, the second closes the pane.
  func testCommandWClosesTheTabThenThePane() {
    let app = launchApp()
    let window = mainWindow(in: app)
    _ = waitForTerminal(in: app)

    app.typeKey("d", modifierFlags: .command)
    app.typeKey(.return, modifierFlags: [])
    XCTAssertTrue(window.groups["pane-2"].textViews["terminal"].appears(timeout: 20))

    app.typeKey("t", modifierFlags: .command)
    XCTAssertTrue(tab(1, in: app).appears(timeout: 10))
    XCTAssertTrue(
      waitFor(window.groups["pane-2"].textViews["terminal"], timeout: 40) { $0.contains("% ") })

    app.typeKey("w", modifierFlags: .command)
    XCTAssertTrue(waitUntilGone(tab(1, in: app), timeout: 15))
    XCTAssertTrue(window.groups["pane-2"].exists, "the pane closed with a tab left")

    app.typeKey("w", modifierFlags: .command)
    XCTAssertTrue(waitUntilGone(window.groups["pane-2"], timeout: 15))
  }

  /// Catches Cmd-Shift-T that does not reach uniterm while the terminal is focused, or a closed tab
  /// that does not return. A second tab opens and closes with Cmd-W. Cmd-Shift-T brings it back
  /// with a fresh shell, and the tab bar shows again.
  func testCommandShiftTReopensAClosedTab() {
    let app = launchApp()
    let window = mainWindow(in: app)
    _ = waitForTerminal(in: app)

    app.typeKey("t", modifierFlags: .command)
    XCTAssertTrue(tab(1, in: app).appears(timeout: 10))
    XCTAssertTrue(waitFor(window.textViews["terminal"], timeout: 40) { $0.contains("% ") })

    app.typeKey("w", modifierFlags: .command)
    XCTAssertTrue(waitUntilGone(tab(1, in: app), timeout: 15))

    app.typeKey("t", modifierFlags: [.command, .shift])

    XCTAssertTrue(tab(1, in: app).appears(timeout: 10), "the closed tab never came back")
    XCTAssertTrue(waitFor(window.textViews["terminal"], timeout: 40) { $0.contains("% ") })
  }

  /// Catches a remap that does not take its reservation. Cmd-T is New Tab until the user puts the
  /// palette on it. Then Cmd-T opens the palette with the terminal focused, the old palette key no
  /// longer does, and the one warning names the applet, the command, and the key.
  func testARemapOntoAnAppletKeyWinsAndWarnsOnce() {
    let app = launchApp(arguments: ["-NSUserKeyEquivalents", #"{"Show Command Palette"="@t";}"#])
    _ = waitForTerminal(in: app)

    let warning = message(in: app)
    XCTAssertTrue(warning.appears(timeout: 10))
    let text = (warning.value as? String) ?? warning.label
    XCTAssertTrue(text.contains("Terminal"), text)
    XCTAssertTrue(text.contains("New Tab"), text)
    XCTAssertTrue(text.contains("\u{2318}T"), text)

    app.typeKey("t", modifierFlags: .command)
    XCTAssertTrue(palette(in: app).appears(timeout: 5), "the remapped key did not win")

    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(waitUntilGone(palette(in: app)))

    app.typeKey("k", modifierFlags: .command)
    XCTAssertFalse(palette(in: app).appears(timeout: 2), "the old default still works")
  }

  /// Catches a remap of an applet item that loses to the default of a window command. Cmd-W is
  /// Close, and the user's remap of Clear Screen onto it must win with the terminal focused.
  func testARemapOfAnAppletItemOntoAWindowKeyWins() {
    let app = launchApp(arguments: ["-NSUserKeyEquivalents", #"{"Clear Screen"="@w";}"#])
    let terminal = waitForTerminal(in: app)

    app.typeText("echo \"C:$((40+2)):\"\n")
    XCTAssertTrue(waitFor(terminal, timeout: 40) { $0.contains("C:42:") })

    app.typeKey("w", modifierFlags: .command)

    XCTAssertTrue(waitFor(terminal, timeout: 10) { !$0.contains("C:42:") })
    XCTAssertTrue(mainWindow(in: app).exists, "Close ran instead")
  }

  /// Catches Cut, Copy, Paste, and Select All that work in the terminal but not in the launcher's
  /// fields. The text is cut from the filter field and pasted back.
  func testEditKeysWorkInTheLauncherField() {
    let app = launchApp()
    let window = mainWindow(in: app)
    _ = waitForTerminal(in: app)

    app.typeKey("d", modifierFlags: .command)
    XCTAssertTrue(launcher(in: window).appears(timeout: 5))

    let field = window.textFields["launcher-filter"]
    XCTAssertTrue(field.appears(timeout: 5))

    app.typeText("zzq")
    app.typeKey("a", modifierFlags: .command)
    app.typeKey("x", modifierFlags: .command)
    XCTAssertTrue(waitFor(field, timeout: 5) { $0.isEmpty })

    app.typeKey("v", modifierFlags: .command)
    XCTAssertTrue(waitFor(field, timeout: 5) { $0 == "zzq" })
  }
}
