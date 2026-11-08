import XCTest

/// Drives several windows in the launched app. Each test proves a contract that only real window
/// ordering, key routing, and the app's lifecycle can show.
///
/// The first window is `main-window`. A later one takes `main-window-2`, `main-window-3`, and so
/// on, and a number is never reused.
@MainActor
final class WindowsUITests: UnitermUITestCase {
  private static let errorText = "ui test error"

  /// Catches a new-window key that does nothing, or a second window that shares the first's shell.
  /// Cmd-N opens a second window with its own prompt. Text typed into it reaches its shell and not
  /// the first window's.
  func testCommandNOpensASecondWindowWithItsOwnShell() {
    let app = launchApp()
    let first = waitForTerminal(in: app)

    app.typeKey("n", modifierFlags: .command)
    let second = waitForTerminal(in: app, window: 2)

    app.typeText("echo \"W:$((6*7)):\"\n")

    XCTAssertTrue(waitFor(second, timeout: 20) { $0.contains("W:42:") }, "the new shell never ran")
    XCTAssertFalse(
      (first.value as? String ?? "").contains("W:42:"), "the first window got the text")
  }

  /// Catches a menu action that lands in the wrong window. With the second window key, Cmd-D
  /// splits it, and the first window keeps its one pane.
  func testPaneActionsGoToTheKeyWindowOnly() {
    let app = launchApp()
    _ = waitForTerminal(in: app)
    app.typeKey("n", modifierFlags: .command)
    _ = waitForTerminal(in: app, window: 2)
    let one = mainWindow(1, in: app)
    let two = mainWindow(2, in: app)

    openPane(in: app, window: 2, keys: "d", modifiers: .command)

    XCTAssertTrue(waitForPaneCount(2, in: two), "the second window never split")
    XCTAssertEqual(paneGroups(in: one).count, 1, "the split reached the first window")
    XCTAssertFalse(launcher(in: one).exists)
  }

  /// Catches a status message that shows in every window. The error posted at launch belongs to the
  /// first window. The second window's bar shows none of it, and has no unseen-error indicator.
  func testAMessageInOneWindowNeverAppearsInAnother() {
    let app = launchApp(environment: ["UNITERM_DEBUG_POST_ERROR": Self.errorText])
    _ = waitForTerminal(in: app)
    let first = mainWindow(1, in: app)
    XCTAssertTrue(
      waitFor(first.staticTexts["status-message"], timeout: 5) { $0.contains(Self.errorText) })

    app.typeKey("n", modifierFlags: .command)
    _ = waitForTerminal(in: app, window: 2)
    let second = mainWindow(2, in: app)

    XCTAssertTrue(second.groups["status-bar"].waitForExistence(timeout: 10))
    XCTAssertFalse(
      ((second.staticTexts["status-message"].value as? String) ?? "").contains(Self.errorText),
      "the second bar shows the first window's error")
    XCTAssertFalse(second.descendants(matching: .any)["status-unseen-error"].exists)
    XCTAssertTrue(first.descendants(matching: .any)["status-unseen-error"].exists)
  }

  /// Catches a dock setting that moves one window's bar and leaves the other behind. Both bars sit
  /// above their terminals after the change, and below them after the change back.
  func testChangingTheDockPositionMovesEveryWindow() {
    let app = launchApp()
    _ = waitForTerminal(in: app)
    app.typeKey("n", modifierFlags: .command)
    _ = waitForTerminal(in: app, window: 2)

    chooseStatusBarPosition("Top", in: app)
    for number in [1, 2] {
      XCTAssertTrue(waitForBar(above: true, window: number, in: app), "window \(number) kept it")
    }

    chooseStatusBarPosition("Bottom", in: app)
    for number in [1, 2] {
      XCTAssertTrue(
        waitForBar(above: false, window: number, in: app), "window \(number) never moved back")
    }
  }

  /// Catches an app that quits with its last window, or a new-window key that is dead without one.
  /// Closing the only window leaves the app running, and Cmd-N opens a window with a working shell.
  func testClosingTheLastWindowKeepsTheAppRunningAndCommandNOpensAgain() {
    let app = launchApp()
    _ = waitForTerminal(in: app)

    app.typeKey("w", modifierFlags: .command)
    XCTAssertTrue(waitUntilGone(mainWindow(1, in: app), timeout: 15))
    XCTAssertTrue(waitForForeground(app), "the app left the foreground")

    app.typeKey("n", modifierFlags: .command)
    let terminal = waitForTerminal(in: app, window: 2)

    app.typeText("echo \"A:$((6*7)):\"\n")
    XCTAssertTrue(waitFor(terminal, timeout: 20) { $0.contains("A:42:") })
  }

  /// Catches a window close that takes down the other windows. Cmd-W closes the key window only.
  /// The first window keeps its shell.
  func testCommandWClosesOnlyTheKeyWindow() {
    let app = launchApp()
    let first = waitForTerminal(in: app)
    app.typeKey("n", modifierFlags: .command)
    _ = waitForTerminal(in: app, window: 2)

    app.typeKey("w", modifierFlags: .command)

    XCTAssertTrue(waitUntilGone(mainWindow(2, in: app), timeout: 15))
    XCTAssertTrue(mainWindow(1, in: app).exists)
    XCTAssertTrue(waitForForeground(app), "the app left the foreground")

    mainWindow(1, in: app).click()
    app.typeText("echo \"K:$((6*7)):\"\n")
    XCTAssertTrue(waitFor(first, timeout: 20) { $0.contains("K:42:") })
  }

  // MARK: Helpers

  private func paneGroups(in window: XCUIElement) -> XCUIElementQuery {
    window.groups.matching(NSPredicate(format: "identifier BEGINSWITH 'pane-'"))
  }

  private func waitForPaneCount(_ count: Int, in window: XCUIElement, timeout: TimeInterval = 20)
    -> Bool
  {
    let deadline = Date().addingTimeInterval(timeout)

    while Date() < deadline {
      if paneGroups(in: window).count == count { return true }

      Thread.sleep(forTimeInterval: 0.25)
    }

    return false
  }

  /// Waits for the bar to sit above the terminal, or below it when `above` is false.
  private func waitForBar(above expected: Bool, window number: Int, in app: XCUIApplication)
    -> Bool
  {
    let window = mainWindow(number, in: app)
    let bar = window.groups["status-bar"]
    let terminal = window.textViews["terminal"]
    let deadline = Date().addingTimeInterval(10)

    while Date() < deadline {
      if bar.exists, terminal.exists {
        let above = bar.frame.maxY <= terminal.frame.minY + 1
        let below = bar.frame.minY >= terminal.frame.maxY - 1
        if expected ? above : below { return true }
      }

      Thread.sleep(forTimeInterval: 0.25)
    }

    return false
  }
}
