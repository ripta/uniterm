import XCTest

/// Drives the status bar region in the launched app. Each test proves a contract that only the
/// window server and real events can show.
///
/// Errors come from a debug hook in the app that posts one at launch. No test depends on a feature
/// that is expected to change.
@MainActor
final class StatusBarUITests: UnitermUITestCase {
  private static let errorText = "ui test error"

  /// Catches a top-docked bar under the traffic lights, or one that breaks dragging the window by
  /// its top edge.
  func testTopDockedBarClearsTheTrafficLightsAndTheWindowStillDrags() {
    let app = launchApp()
    let window = app.windows["main-window"]
    let terminal = waitForTerminal(in: app)
    let bar = window.groups["status-bar"]
    XCTAssertTrue(bar.waitForExistence(timeout: 10))
    XCTAssertGreaterThanOrEqual(
      bar.frame.minY, terminal.frame.maxY - 1, "the bar starts at the bottom")

    chooseStatusBarPosition("Top", in: app)
    XCTAssertTrue(
      waitForFrame(bar) { $0.maxY <= terminal.frame.minY + 1 },
      "the bar never moved above the terminal")

    let lights = [
      window.buttons[XCUIIdentifierCloseWindow],
      window.buttons[XCUIIdentifierMinimizeWindow],
      window.buttons[XCUIIdentifierFullScreenWindow],
    ]
    for light in lights {
      XCTAssertTrue(light.isHittable, "a traffic light is covered")
      XCTAssertFalse(bar.frame.intersects(light.frame), "the bar overlaps a traffic light")
      XCTAssertGreaterThanOrEqual(bar.frame.minY, light.frame.maxY - 1, "the bar is under a light")
    }

    let before = window.frame
    let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(
      CGVector(dx: 0, dy: 10))
    start.press(forDuration: 0.2, thenDragTo: start.withOffset(CGVector(dx: 120, dy: 80)))

    let after = window.frame
    XCTAssertEqual(after.origin.x - before.origin.x, 120, accuracy: 20)
    XCTAssertEqual(after.origin.y - before.origin.y, 80, accuracy: 20)

    chooseStatusBarPosition("Bottom", in: app)
    XCTAssertTrue(
      waitForFrame(bar) { $0.minY >= terminal.frame.maxY - 1 },
      "the bar never moved back below the terminal")
  }

  /// Catches a bar that cannot expand into the history, or a history that hides level or source.
  func testClickingTheBarShowsTheHistoryWithLevelAndSource() {
    let app = launchApp(environment: ["UNITERM_DEBUG_POST_ERROR": Self.errorText])
    let window = app.windows["main-window"]
    _ = waitForTerminal(in: app)
    let message = window.staticTexts["status-message"]
    XCTAssertTrue(waitFor(message, timeout: 5) { $0.contains(Self.errorText) })

    let bar = window.groups["status-bar"]
    bar.click()

    let rows = window.staticTexts.matching(identifier: "history-row")
    XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5), "the history never opened")
    XCTAssertGreaterThanOrEqual(rows.count, 1)
    XCTAssertEqual(
      rows.element(boundBy: 0).value as? String, "error  uniterm: \(Self.errorText)")

    bar.click()
    XCTAssertTrue(waitForGone(rows.firstMatch), "a second click left the history open")
  }

  /// Catches an unseen-error indicator that never shows, or one that stays after the history is
  /// opened with its menu key and shows the error's row.
  func testAnErrorRaisesTheIndicatorAndOpeningTheHistoryClearsIt() {
    let app = launchApp(environment: ["UNITERM_DEBUG_POST_ERROR": Self.errorText])
    let window = app.windows["main-window"]
    _ = waitForTerminal(in: app)

    let indicator = element("status-unseen-error", in: window)
    XCTAssertTrue(indicator.waitForExistence(timeout: 5), "no indicator after an error")

    app.typeKey("m", modifierFlags: [.command, .shift])

    let rows = window.staticTexts.matching(identifier: "history-row")
    XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
    XCTAssertEqual(rows.firstMatch.value as? String, "error  uniterm: \(Self.errorText)")
    XCTAssertTrue(waitForGone(indicator), "opening the history left the indicator on")
  }

  /// Catches a dismiss key that does not reach uniterm from a focused terminal.
  func testTheDismissKeyClearsAnError() {
    let app = launchApp(environment: ["UNITERM_DEBUG_POST_ERROR": Self.errorText])
    let window = app.windows["main-window"]
    _ = waitForTerminal(in: app)
    let message = window.staticTexts["status-message"]
    XCTAssertTrue(waitFor(message, timeout: 5) { $0.contains(Self.errorText) })

    app.typeKey(.delete, modifierFlags: [.command, .option])

    XCTAssertTrue(waitForMessageToLeave(message), "the error stayed on the bar")
    XCTAssertTrue(waitForGone(element("status-dismiss", in: window)))
  }

  /// Catches a dismiss control that is missing from an error, or that does not dismiss.
  func testClickingTheDismissControlClearsAnError() {
    let app = launchApp(environment: ["UNITERM_DEBUG_POST_ERROR": Self.errorText])
    let window = app.windows["main-window"]
    _ = waitForTerminal(in: app)
    let message = window.staticTexts["status-message"]
    XCTAssertTrue(waitFor(message, timeout: 5) { $0.contains(Self.errorText) })

    let dismiss = element("status-dismiss", in: window)
    XCTAssertTrue(dismiss.waitForExistence(timeout: 5), "an error has no dismiss control")
    dismiss.click()

    XCTAssertTrue(waitForMessageToLeave(message), "the error stayed on the bar")
    XCTAssertFalse(window.groups["status-history"].exists)
  }

  // MARK: Helpers

  /// A segment's icon is exposed as a generic element, so the query ignores the element type.
  private func element(_ identifier: String, in window: XCUIElement) -> XCUIElement {
    window.descendants(matching: .any)[identifier]
  }

  /// An empty label may report no value at all, so absence counts as gone.
  private func waitForMessageToLeave(_ message: XCUIElement) -> Bool {
    let deadline = Date().addingTimeInterval(5)

    while Date() < deadline {
      if !((message.value as? String) ?? "").contains(Self.errorText) { return true }

      Thread.sleep(forTimeInterval: 0.25)
    }

    return false
  }

  private func waitForFrame(_ element: XCUIElement, _ condition: @escaping (CGRect) -> Bool)
    -> Bool
  {
    let deadline = Date().addingTimeInterval(10)

    while Date() < deadline {
      if element.exists, condition(element.frame) { return true }

      Thread.sleep(forTimeInterval: 0.25)
    }

    return false
  }

  private func waitForGone(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
    let gone = NSPredicate(format: "exists == false")
    return XCTWaiter().wait(
      for: [XCTNSPredicateExpectation(predicate: gone, object: element)], timeout: timeout)
      == .completed
  }
}
