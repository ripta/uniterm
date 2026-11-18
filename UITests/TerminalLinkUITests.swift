import XCTest

/// Hovers and clicks a path printed in the app's own terminal, with Command held, and checks what
/// the window server and AppKit show. The package tests prove the rules that decide what a click
/// may open. What only the real app shows is the overlay at the bottom left of the pane, the
/// pointer reaching libghostty with the modifier, and the routed pane landing beside the clicked one.
///
/// A folder is the target. A folder routed to the terminal opens a new terminal there, so no viewer
/// is needed to see the open.
@MainActor
final class TerminalLinkUITests: UnitermUITestCase {
  private func makeFolder() throws -> URL {
    let name = "uniterm-click-\(UUID().uuidString.prefix(8))"
    let folder = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent(name, isDirectory: true)

    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }

    return folder.resolvingSymlinksInPath()
  }

  /// Clears the screen and prints the text on the first row, so the test knows where it is. The
  /// command has no quote or backslash, since the typed events mangle both. A typed apostrophe
  /// reaches the shell as a control key sequence.
  private func printText(_ text: String, in app: XCUIApplication, terminal: XCUIElement) {
    app.typeText("clear; echo \(text)\n")

    XCTAssertTrue(
      waitFor(terminal, timeout: 40) { $0.hasPrefix(String(text.prefix(20))) },
      "the text never reached the first row. Screen: \(terminal.value as? String ?? "")")
  }

  /// A point inside the first row's text, a few cells in.
  private func firstRow(of terminal: XCUIElement) -> XCUICoordinate {
    terminal.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 40, dy: 12))
  }

  /// A point in the empty lower part of the terminal, where no link is.
  private func emptyArea(of terminal: XCUIElement) -> XCUICoordinate {
    terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
  }

  /// Brings the pointer onto the point from the empty area, with Command already held, so the
  /// terminal sees real movement across cells. The system pointer stays where the last test left
  /// it, and a hover to that same spot sends no move at all. libghostty drops a move of under one
  /// pixel as well, so a repeated hover to one spot never reports a link. Without a move, it has no
  /// pointer position, and neither the hover nor the click finds the link.
  private func moveOnto(_ point: XCUICoordinate, from empty: XCUICoordinate) {
    empty.hover()
    point.hover()
    point.withOffset(CGVector(dx: 8, dy: 0)).hover()
    point.hover()
  }

  /// Catches a hover that shows no target, a click that opens nothing, and a routed pane that lands
  /// in another window or takes no place beside the clicked pane. With Command held over the path
  /// the overlay names it. A Command-click then opens a new terminal beside the first.
  func testCommandHoverShowsTheTargetAndCommandClickOpensItBesideThePane() throws {
    let folder = try makeFolder()
    let app = launchApp()
    let window = mainWindow(in: app)
    let terminal = waitForTerminal(in: app)

    XCTAssertFalse(window.groups["pane-2"].exists)

    printText(folder.path, in: app, terminal: terminal)

    let preview = window.staticTexts["terminal-link-preview"]
    let point = firstRow(of: terminal)

    XCTAssertFalse(preview.exists, "the overlay showed with no link under the pointer")

    XCUIElement.perform(withKeyModifiers: .command) {
      moveOnto(point, from: emptyArea(of: terminal))

      XCTAssertTrue(
        preview.waitForExistence(timeout: 10), "no overlay with Command held over the path")
      XCTAssertEqual(preview.value as? String, folder.path)

      let shot = XCTAttachment(screenshot: window.screenshot())

      shot.name = "link-overlay"
      shot.lifetime = .keepAlways
      add(shot)

      point.click()
    }

    XCTAssertTrue(
      window.groups["pane-2"].textViews["terminal"].waitForExistence(timeout: 20),
      "the click opened no pane beside the first")
    XCTAssertFalse(app.windows["main-window-2"].exists, "the folder opened in a new window")
  }

  /// Catches a click on a relative path that opens something, or fails without a word. The text is
  /// the kind a remote `ls` prints. No overlay shows, no pane opens, and the status bar says why.
  func testCommandClickOnARelativePathOpensNothingAndSaysWhy() throws {
    let app = launchApp()
    let window = mainWindow(in: app)
    let terminal = waitForTerminal(in: app)

    printText("notes/readme.txt", in: app, terminal: terminal)

    let point = firstRow(of: terminal)

    XCUIElement.perform(withKeyModifiers: .command) {
      moveOnto(point, from: emptyArea(of: terminal))

      XCTAssertFalse(
        window.staticTexts["terminal-link-preview"].waitForExistence(timeout: 2),
        "a relative path showed a target")

      point.click()
    }

    let message = window.staticTexts["status-message"]

    XCTAssertTrue(message.waitForExistence(timeout: 10), "the refusal never reached the status bar")
    XCTAssertTrue(
      waitFor(message, timeout: 5) { $0.contains("Not opened: a relative path") },
      "the message does not say why. It reads \(message.value as? String ?? "")")
    XCTAssertFalse(window.groups["pane-2"].exists, "a relative path opened a pane")
  }
}
