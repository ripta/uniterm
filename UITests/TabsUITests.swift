import XCTest

/// Drives terminal tabs and program mode in the launched app. Each test proves a contract that only
/// AppKit's key routing, the menu, and real sheets can show.
///
/// The tab bar exposes each tab as `tab-N` with the value `selected` or `unselected`. Icon-only
/// controls do not report a fixed element type, so tests query by identifier across all types.
///
/// Every shell comes from the shared launch helper, so none reads the developer's dotfiles. A
/// tab is only closed after its shell showed a prompt, since a shell that has not reached its
/// first prompt reads as running something.
@MainActor
final class TabsUITests: UnitermUITestCase {
  private func tab(_ index: Int, in app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any)["tab-\(index)"]
  }

  private func waitForGone(_ element: XCUIElement, timeout: TimeInterval = 15) -> Bool {
    element.disappears(timeout: timeout)
  }

  private func waitForValue(_ value: String, of element: XCUIElement) -> Bool {
    waitFor(element, timeout: 10) { $0 == value }
  }

  /// Opens a tab and waits for its shell to show a prompt.
  private func openTab(in app: XCUIApplication) -> XCUIElement {
    let window = app.windows["main-window"]
    app.typeKey("t", modifierFlags: .command)

    let terminal = window.textViews["terminal"]
    XCTAssertTrue(terminal.appears(timeout: 15))
    XCTAssertTrue(
      waitFor(terminal, timeout: 40) { $0.contains("% ") }, "the new tab never showed a prompt")
    return terminal
  }

  /// Catches a tab bar that shows for one tab, and tabs that share a tty. A single tab has no bar.
  /// Cmd-T adds a second tab and shows the bar. Each tab reports its own terminal device, and
  /// Cmd-1 and Cmd-2 switch between them.
  func testNewTabsShowTheBarAndEachRunsItsOwnShell() throws {
    let app = launchApp()
    let terminal = waitForTerminal(in: app)
    XCTAssertFalse(tab(0, in: app).exists, "a single tab showed the bar")

    let pattern = #"Y:(/dev/ttys\d+):"#
    app.typeText("echo \"Y:$(tty):\"\n")
    XCTAssertTrue(
      waitFor(terminal, timeout: 40) { self.firstMatch(pattern, in: $0) != nil },
      "the first tab reported no device")
    let first = try XCTUnwrap(firstMatch(pattern, in: terminal.value as? String ?? ""))

    let second = openTab(in: app)
    XCTAssertTrue(tab(1, in: app).appears(timeout: 10))
    XCTAssertTrue(waitForValue("selected", of: tab(1, in: app)))
    XCTAssertTrue(waitForValue("unselected", of: tab(0, in: app)))

    app.typeText("echo \"Y:$(tty):\"\n")
    XCTAssertTrue(
      waitFor(second, timeout: 40) { self.firstMatch(pattern, in: $0) != nil },
      "the second tab reported no device")
    let other = try XCTUnwrap(firstMatch(pattern, in: second.value as? String ?? ""))
    XCTAssertNotEqual(first, other, "both tabs run on one tty")

    app.typeKey("1", modifierFlags: .command)
    XCTAssertTrue(waitForValue("selected", of: tab(0, in: app)))
    XCTAssertTrue(
      waitFor(terminal, timeout: 10) { $0.contains("Y:\(first):") && !$0.contains("Y:\(other):") })

    app.typeKey("2", modifierFlags: .command)
    XCTAssertTrue(waitForValue("selected", of: tab(1, in: app)))
  }

  /// Catches a hidden tab whose shell keeps its old size through a window resize, so its program
  /// would draw at a stale width. The first tab's shell prints its size on SIGWINCH. The window
  /// narrows while the second tab shows. The first tab then holds a size line with fewer columns,
  /// printed while it was hidden.
  ///
  /// The tab bar's arrival also resizes the hidden tab, but it changes only the rows, so the test
  /// looks for a change in columns.
  func testAHiddenTabsShellSeesTheWindowSize() throws {
    let app = launchApp()
    let window = app.windows["main-window"]
    let terminal = waitForTerminal(in: app)

    app.typeText(
      "TRAPWINCH() { echo \"W:$(stty size | tr \" \" x):\" }; echo \"A:$(stty size | tr \" \" x):\"\n"
    )
    XCTAssertTrue(
      waitFor(terminal, timeout: 40) { self.firstMatch(#"A:\d+x(\d+):"#, in: $0) != nil },
      "the first tab reported no size")
    let columns = try XCTUnwrap(
      firstMatch(#"A:\d+x(\d+):"#, in: terminal.value as? String ?? ""))

    _ = openTab(in: app)
    XCTAssertTrue(waitForValue("selected", of: tab(1, in: app)))

    let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(
      CGVector(dx: -2, dy: -2))
    corner.press(forDuration: 0.1, thenDragTo: corner.withOffset(CGVector(dx: -300, dy: -150)))

    // The hidden shell's line can only be read once its tab shows. Showing it changes no size,
    // since the hidden terminal already fills the same area.
    app.typeKey("1", modifierFlags: .command)
    XCTAssertTrue(waitForValue("selected", of: tab(0, in: app)))

    let narrower = #"W:\d+x(?!\#(columns):)\d+:"#
    let shown = window.textViews["terminal"]
    let sawResize = waitFor(shown, timeout: 20) { self.firstMatch("(\(narrower))", in: $0) != nil }

    let shot = XCTAttachment(screenshot: window.screenshot())
    shot.name = "hidden-tab-after-resize"
    shot.lifetime = .keepAlways
    add(shot)

    XCTAssertTrue(
      sawResize,
      "the hidden tab's shell kept \(columns) columns. Screen: \(shown.value as? String ?? "")")
  }

  /// Catches Ctrl-Tab and Ctrl-Shift-Tab that do not reach uniterm's menu from a focused terminal.
  /// AppKit can take Ctrl-Tab for its focus loop, and Shift-Tab types back-tab, not Tab.
  func testNextAndPreviousTabKeysSwitchTabs() {
    let app = launchApp()
    _ = waitForTerminal(in: app)
    _ = openTab(in: app)
    XCTAssertTrue(waitForValue("selected", of: tab(1, in: app)))

    app.typeKey(.tab, modifierFlags: [.control, .shift])
    XCTAssertTrue(waitForValue("selected", of: tab(0, in: app)), "Ctrl-Shift-Tab did not go back")

    app.typeKey(.tab, modifierFlags: .control)
    XCTAssertTrue(waitForValue("selected", of: tab(1, in: app)), "Ctrl-Tab did not go forward")
  }

  /// Catches Cmd-W that closes the pane while the applet has several tabs. With two tabs at idle
  /// prompts it closes the current tab and hides the bar again. The last tab then closes the pane,
  /// and the window with it.
  func testCommandWClosesTheTabThenThePane() {
    let app = launchApp()
    _ = waitForTerminal(in: app)
    _ = openTab(in: app)
    XCTAssertTrue(tab(1, in: app).appears(timeout: 10))

    app.typeKey("w", modifierFlags: .command)

    XCTAssertTrue(waitForGone(tab(1, in: app)), "Cmd-W left the second tab")
    XCTAssertTrue(waitForGone(tab(0, in: app)), "the bar stayed with one tab")
    XCTAssertEqual(app.state, .runningForeground)

    app.typeKey("w", modifierFlags: .command)

    XCTAssertTrue(waitUntilGone(mainWindow(in: app), timeout: 15), "the window stayed open")
    XCTAssertEqual(app.state, .runningForeground)
  }

  /// Catches a reopened tab that comes back empty. The second tab prints a marker and closes.
  /// Cmd-Shift-T brings it back with the marker above a fresh prompt.
  func testAReopenedTabShowsItsEarlierOutput() {
    let app = launchApp()
    _ = waitForTerminal(in: app)
    let second = openTab(in: app)

    app.typeText("echo \"RT:$((6*7)):reopen\"\n")
    XCTAssertTrue(waitFor(second, timeout: 20) { $0.contains("RT:42:reopen") })

    app.typeKey("w", modifierFlags: .command)
    XCTAssertTrue(waitForGone(tab(1, in: app)), "Cmd-W left the second tab")

    app.typeKey("t", modifierFlags: [.command, .shift])
    XCTAssertTrue(tab(1, in: app).appears(timeout: 10), "Cmd-Shift-T did not reopen the tab")

    let reopened = app.windows["main-window"].textViews["terminal"]
    XCTAssertTrue(
      waitFor(reopened, timeout: 40) { self.promptFollows("RT:42:reopen", in: $0) },
      "the reopened tab lost its output: \(reopened.value as? String ?? "")")
  }

  /// Catches a tab close that ends a running program without asking. `cat` is running something.
  /// Cmd-W asks, naming the tab. Cancel keeps the tab. Confirming closes it.
  func testClosingATabRunningSomethingAsksFirst() {
    let app = launchApp()
    let window = app.windows["main-window"]
    _ = waitForTerminal(in: app)
    let terminal = openTab(in: app)

    app.typeText("echo \"CR:$((6*7)):\"; cat\n")
    XCTAssertTrue(waitFor(terminal, timeout: 20) { $0.contains("CR:42:") })

    app.typeKey("w", modifierFlags: .command)
    let sheet = window.sheets.firstMatch
    XCTAssertTrue(sheet.appears(timeout: 10), "closing a running tab asked nothing")
    XCTAssertTrue(sheet.buttons["Close Tab"].exists)

    sheet.buttons["Cancel"].click()
    XCTAssertTrue(waitForNoSheet(in: window))
    XCTAssertTrue(tab(1, in: app).exists, "Cancel still closed the tab")

    app.typeKey("w", modifierFlags: .command)
    XCTAssertTrue(sheet.appears(timeout: 10))
    sheet.buttons["Close Tab"].click()

    XCTAssertTrue(waitForGone(tab(1, in: app)), "confirming left the tab open")
  }

  /// Catches program mode that grows tabs. A pane opened in program mode runs the program, has no
  /// tab bar, and the New Tab item is disabled while it has focus.
  func testProgramModeHasNoNewTab() {
    let app = launchApp()
    let window = app.windows["main-window"]
    _ = waitForTerminal(in: app)

    app.typeKey("d", modifierFlags: .command)
    XCTAssertTrue(launcher(in: window).appears(timeout: 5))

    app.typeKey("2", modifierFlags: .command)
    app.typeText("sh -c \"echo PU:42:; cat\"")
    app.typeKey(.return, modifierFlags: [])

    let pane = window.groups["pane-2"]
    XCTAssertTrue(pane.appears(timeout: 20))
    XCTAssertTrue(waitFor(pane.textViews["terminal"], timeout: 40) { $0.contains("PU:42:") })

    app.menuBars.menuBarItems["File"].click()
    let newTab = app.menuBars.menuItems["New Tab"]
    XCTAssertTrue(newTab.appears(timeout: 5))
    XCTAssertFalse(newTab.isEnabled, "New Tab is live in program mode")
    app.typeKey(.escape, modifierFlags: [])

    XCTAssertFalse(pane.descendants(matching: .any)["tab-0"].exists)
  }
}
