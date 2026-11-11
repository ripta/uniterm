import XCTest

/// The pane control badge and actions in the real app, with a real terminal holding the keyboard.
/// A terminal takes every key it can, so the actions must work from the menu and the badge alone.
@MainActor
final class PaneControlUITests: UnitermUITestCase {
  /// Catches a pane that starts remote-controlled, a remote-controlled pane with no marker, and a
  /// badge whose menu cannot take control away while the terminal holds the keyboard. The File
  /// menu enables the pane, the badge appears, and its menu disconnects the pane again.
  func testTheBadgeMarksARemoteControlledPaneAndItsMenuDisconnectsIt() {
    let app = launchApp()
    let window = mainWindow(in: app)
    let terminal = waitForTerminal(in: app)
    let badge = window.buttons["pane-control-1"]

    XCTAssertFalse(badge.exists, "a new pane showed a control badge")

    terminal.click()
    enableRemoteControl(pane: 1, in: app)

    XCTAssertEqual(badge.value as? String, "remote-controlled")
    keepScreenshot(of: window, named: "Remote-controlled pane with its control badge")

    badge.click()

    let disconnect = app.menuItems["pane-control-disconnect"]
    let menu = app.menus.containing(.menuItem, identifier: "pane-control-disconnect").firstMatch

    XCTAssertTrue(disconnect.waitForExistence(timeout: 5), "the badge showed no menu")
    XCTAssertTrue(hasFrame(menu, timeout: 5), "the badge's menu has no frame")
    keepScreenshot(of: menu, named: "Control badge menu open")
    disconnect.click()

    XCTAssertTrue(waitUntilGone(badge), "the badge stayed after a disconnect")
  }

  /// Waits until the element exists and takes up room on screen. A screenshot of an element with an
  /// empty frame fails.
  private func hasFrame(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)

    while Date() < deadline {
      if element.exists, !element.frame.isEmpty { return true }

      Thread.sleep(forTimeInterval: 0.25)
    }

    return false
  }

  /// Keeps a screenshot with the test's results, so a reviewer sees the badge as the user does.
  /// A menu draws outside the window, so its shot is of the menu element alone. Neither shot
  /// covers anything but uniterm's own UI.
  private func keepScreenshot(of element: XCUIScreenshotProviding, named name: String) {
    let attachment = XCTAttachment(screenshot: element.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
