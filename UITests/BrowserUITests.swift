import AppKit
import XCTest

/// Drives the browser in the launched app. Each test proves a contract that needs the real window
/// server: the launcher entry, and a pane restored from a saved layout by its description type.
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
}
