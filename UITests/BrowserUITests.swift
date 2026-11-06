import AppKit
import XCTest

/// Drives the browser in the launched app. Each test proves a contract that needs the real window
/// server: the launcher entry, a pane restored from a saved layout by its description type, and the
/// keys that reach the browser's tabs through the menu.
///
/// The tab bar exposes each tab as `tab-N` with the value `selected` or `unselected`, as the
/// terminal's does.
///
/// No test loads a page from the network. A restored `about:blank` is the one address that loads
/// without a server.
@MainActor
final class BrowserUITests: UnitermUITestCase {
  private func plantBrowser(payload: String, version: Int = 1) throws {
    try plantLayout(
      """
      {"version":1,"windows":[{"frame":{"x":100,"y":100,"width":900,"height":600},"highWaterMark":1,
      "tree":{"kind":"pane","id":1,"applet":{"type":"browser","version":\(version),
      "payload":\(payload)}}}]}
      """)
  }

  private func browser(in window: XCUIElement) -> XCUIElement {
    window.descendants(matching: .any)["browser"]
  }

  private func addressField(in window: XCUIElement) -> XCUIElement {
    window.descendants(matching: .any)["browser-address"]
  }

  private func tab(_ index: Int, in window: XCUIElement) -> XCUIElement {
    window.descendants(matching: .any)["tab-\(index)"]
  }

  private func waitForGone(_ element: XCUIElement, timeout: TimeInterval = 15) -> Bool {
    let gone = NSPredicate(format: "exists == false")
    return XCTWaiter().wait(
      for: [XCTNSPredicateExpectation(predicate: gone, object: element)], timeout: timeout)
      == .completed
  }

  private func isSelected(_ element: XCUIElement) -> Bool {
    waitFor(element, timeout: 10) { $0 == "selected" }
  }

  /// Opens a browser pane from the launcher and waits for it.
  private func openBrowser(in app: XCUIApplication) -> XCUIElement {
    let window = mainWindow(in: app)
    _ = waitForTerminal(in: app)

    app.typeKey("d", modifierFlags: .command)
    XCTAssertTrue(launcher(in: window).waitForExistence(timeout: 5))

    app.typeKey("5", modifierFlags: .command)
    app.typeKey(.return, modifierFlags: [])

    XCTAssertTrue(waitUntilGone(launcher(in: window)))
    XCTAssertTrue(browser(in: window).waitForExistence(timeout: 10), "no browser pane")

    return window
  }

  /// Catches a launcher without the browser, a row that opens something else, and a new browser
  /// pane with no toolbar. Cmd-D shows the launcher, Cmd-5 picks the browser, and Return opens it.
  /// The pane shows its buttons and an empty address bar, with back and forward off.
  func testLauncherOpensABrowserWithItsToolbar() throws {
    let app = launchApp()
    let window = mainWindow(in: app)
    _ = waitForTerminal(in: app)

    app.typeKey("d", modifierFlags: .command)
    XCTAssertTrue(launcher(in: window).waitForExistence(timeout: 5))
    XCTAssertTrue(
      window.descendants(matching: .any)["launcher-browser"].waitForExistence(timeout: 5),
      "the launcher has no browser row")

    app.typeKey("5", modifierFlags: .command)
    app.typeKey(.return, modifierFlags: [])

    XCTAssertTrue(waitUntilGone(launcher(in: window)))
    XCTAssertTrue(browser(in: window).waitForExistence(timeout: 10), "no browser pane")

    let toolbar = browser(in: window)

    XCTAssertTrue(toolbar.buttons["browser-back"].exists)
    XCTAssertTrue(toolbar.buttons["browser-forward"].exists)
    XCTAssertTrue(toolbar.buttons["browser-reload"].exists)
    XCTAssertFalse(toolbar.buttons["browser-back"].isEnabled)
    XCTAssertFalse(toolbar.buttons["browser-forward"].isEnabled)
    XCTAssertEqual(addressField(in: window).value as? String ?? "", "")
  }

  /// Catches a restore that does not pick the browser by its description type, which would show a
  /// placeholder. A planted layout holds a browser at `about:blank`, and the pane comes back as a
  /// browser with an empty address bar.
  func testALayoutWithABrowserRestoresABrowserPane() throws {
    try plantBrowser(payload: #"{"tabs":[{"url":"about:blank","title":"Notes"}],"selected":0}"#)

    let app = launchApp()
    let window = mainWindow(in: app)

    XCTAssertTrue(browser(in: window).waitForExistence(timeout: 15), "no browser pane restored")
    XCTAssertTrue(addressField(in: window).exists)
    XCTAssertEqual(addressField(in: window).value as? String ?? "", "")
  }

  /// Catches a description from a newer build restored as a browser, which would drop its fields.
  /// The window opens and holds no browser pane. Whether the layout keeps the bytes is the layout
  /// tests' to prove.
  func testADescriptionFromANewerVersionIsNotRestoredAsABrowser() throws {
    try plantBrowser(payload: #"{"tabs":[{"url":"about:blank"}],"selected":0}"#, version: 2)

    let app = launchApp()
    let window = mainWindow(in: app)

    XCTAssertTrue(window.waitForExistence(timeout: 15))
    XCTAssertFalse(browser(in: window).waitForExistence(timeout: 3))
  }

  /// Catches a tab bar that shows for one tab, and tab keys that do not reach the browser through
  /// the menu. A new pane has no bar. Cmd-T adds a tab and selects it. Cmd-Shift-[ and Cmd-Shift-]
  /// step through the tabs, Cmd-1 and Cmd-2 pick one, and Cmd-9 picks the last.
  func testTheTabKeysOpenAndSwitchBrowserTabs() {
    let app = launchApp()
    let window = openBrowser(in: app)

    XCTAssertFalse(tab(0, in: window).exists, "a single tab showed the bar")

    app.typeKey("t", modifierFlags: .command)

    XCTAssertTrue(tab(1, in: window).waitForExistence(timeout: 10), "Cmd-T opened no tab")
    XCTAssertTrue(isSelected(tab(1, in: window)))

    app.typeKey("[", modifierFlags: [.command, .shift])
    XCTAssertTrue(isSelected(tab(0, in: window)), "Cmd-Shift-[ did not go back")

    app.typeKey("]", modifierFlags: [.command, .shift])
    XCTAssertTrue(isSelected(tab(1, in: window)), "Cmd-Shift-] did not go forward")

    app.typeKey("1", modifierFlags: .command)
    XCTAssertTrue(isSelected(tab(0, in: window)), "Cmd-1 did not pick the first tab")

    app.typeKey("9", modifierFlags: .command)
    XCTAssertTrue(isSelected(tab(1, in: window)), "Cmd-9 did not pick the last tab")
  }

  /// Catches Cmd-W that closes the pane while the browser has several tabs, and a reopen that loses
  /// the tab. Cmd-W closes the current tab and hides the bar again. Cmd-Shift-T brings the tab back.
  func testCommandWClosesTheTabAndCommandShiftTReopensIt() {
    let app = launchApp()
    let window = openBrowser(in: app)

    app.typeKey("t", modifierFlags: .command)
    XCTAssertTrue(tab(1, in: window).waitForExistence(timeout: 10))

    app.typeKey("w", modifierFlags: .command)

    XCTAssertTrue(waitForGone(tab(1, in: window)), "Cmd-W left the second tab")
    XCTAssertTrue(waitForGone(tab(0, in: window)), "the bar stayed with one tab")
    XCTAssertTrue(browser(in: window).exists, "Cmd-W closed the pane")

    app.typeKey("t", modifierFlags: [.command, .shift])

    XCTAssertTrue(tab(1, in: window).waitForExistence(timeout: 10), "Cmd-Shift-T brought no tab")
    XCTAssertTrue(isSelected(tab(1, in: window)))
  }

  /// Catches Cmd-L that does not reach the address bar. After Cmd-T moves the keyboard to the new
  /// tab's bar, Cmd-L still focuses it, and typed text lands there.
  func testCommandLFocusesTheAddressBar() {
    let app = launchApp()
    let window = openBrowser(in: app)

    app.typeKey("t", modifierFlags: .command)
    XCTAssertTrue(tab(1, in: window).waitForExistence(timeout: 10))

    app.typeKey("l", modifierFlags: .command)
    app.typeText("about:blank")

    XCTAssertTrue(
      waitFor(addressField(in: window), timeout: 10) { $0 == "about:blank" },
      "Cmd-L did not focus the address bar")
  }
}
