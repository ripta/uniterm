import XCTest

/// Drives the launched app. Each test proves a contract that unit tests cannot reach, because the
/// behavior belongs to AppKit and the window server.
///
/// The app reads a throwaway plist inside the runner's container, so no test touches the
/// developer's preferences. An out-of-process `defaults write` cannot be proven here. The runner
/// only seeds settings through the launch, and it cannot write the app's real domain. The store's
/// reaction to such a write is covered in the package tests.
@MainActor
final class WindowChromeUITests: UnitermUITestCase {
  /// Catches a content view that covers the traffic lights, or lights that stop working under a
  /// full-size content view.
  func testTrafficLightsStayVisibleClickableAndUncovered() {
    let app = launchApp()
    let window = app.windows["main-window"]
    XCTAssertTrue(window.waitForExistence(timeout: 10))

    let close = window.buttons[XCUIIdentifierCloseWindow]
    let minimize = window.buttons[XCUIIdentifierMinimizeWindow]
    let zoom = window.buttons[XCUIIdentifierFullScreenWindow]
    for button in [close, minimize, zoom] {
      XCTAssertTrue(button.exists)
      XCTAssertTrue(button.isHittable, "a traffic light is covered or disabled")
    }

    let terminal = window.textViews["terminal"]
    XCTAssertTrue(terminal.waitForExistence(timeout: 10))
    for button in [close, minimize, zoom] {
      XCTAssertFalse(terminal.frame.intersects(button.frame), "content overlaps a traffic light")
    }
    XCTAssertGreaterThan(
      terminal.frame.minY, close.frame.maxY - 1, "content starts above the title bar")
  }

  /// Catches a full-size content view that eats mouse-downs in the title bar, so the window no
  /// longer drags by its top edge.
  func testWindowDragsByTopEdge() {
    let app = launchApp()
    let window = app.windows["main-window"]
    XCTAssertTrue(window.waitForExistence(timeout: 10))

    let before = window.frame
    let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(
      CGVector(dx: 0, dy: 10))
    let end = start.withOffset(CGVector(dx: 120, dy: 80))
    start.press(forDuration: 0.2, thenDragTo: end)

    let after = window.frame
    XCTAssertEqual(after.origin.x - before.origin.x, 120, accuracy: 20)
    XCTAssertEqual(after.origin.y - before.origin.y, 80, accuracy: 20)
    XCTAssertEqual(after.size.width, before.size.width, accuracy: 1)
  }

  /// Catches a missing Cmd-, binding, a Settings window that does not write the setting, and a
  /// window that needs a relaunch to change theme.
  func testCommandCommaOpensSettingsAndChangesAppearanceLive() {
    let app = launchApp()
    let window = app.windows["main-window"]
    XCTAssertTrue(window.waitForExistence(timeout: 10))
    let content = window.groups["content-area"]

    app.typeKey(",", modifierFlags: .command)
    let settings = app.windows["settings-window"]
    XCTAssertTrue(settings.waitForExistence(timeout: 5))

    let control = settings.radioGroups["appearance-control"]
    XCTAssertTrue(control.waitForExistence(timeout: 5))

    control.radioButtons["Dark"].click()
    XCTAssertTrue(waitForValue("mocha", of: content))

    control.radioButtons["Light"].click()
    XCTAssertTrue(waitForValue("latte", of: content))

    control.radioButtons["System"].click()
    XCTAssertEqual(control.radioButtons["System"].value as? Int, 1)
  }

  /// Catches a Cmd-W that does nothing when Settings is the key window. The Close item targets the
  /// pane, so the Settings window answers it. The main window stays open.
  func testCommandWClosesTheSettingsWindowAndNotTheMainWindow() {
    let app = launchApp()
    let window = app.windows["main-window"]
    XCTAssertTrue(window.waitForExistence(timeout: 10))

    app.typeKey(",", modifierFlags: .command)
    let settings = app.windows["settings-window"]
    XCTAssertTrue(settings.waitForExistence(timeout: 5))

    app.typeKey("w", modifierFlags: .command)

    let gone = NSPredicate(format: "exists == false")
    XCTAssertEqual(
      XCTWaiter().wait(
        for: [XCTNSPredicateExpectation(predicate: gone, object: settings)], timeout: 5),
      .completed)
    XCTAssertTrue(window.exists)
  }

  private func waitForValue(_ expected: String, of element: XCUIElement) -> Bool {
    let predicate = NSPredicate(format: "value == %@", expected)
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
    return XCTWaiter().wait(for: [expectation], timeout: 5) == .completed
  }
}
