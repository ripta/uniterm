import XCTest

/// Restarts a REPL with a capability through its menu, as a user would. What only the real app
/// shows is the menu item, the sheet's warning and checkboxes, and the fresh helper that the real
/// terminal starts with the chosen flag. The package tests prove the launch words, the channel,
/// and the description.
@MainActor
final class ReplCapabilityUITests: UnitermUITestCase {
  private func openRepl(in app: XCUIApplication) -> XCUIElement {
    let window = mainWindow(in: app)

    _ = waitForTerminal(in: app)

    app.typeKey("d", modifierFlags: .command)
    XCTAssertTrue(launcher(in: window).waitForExistence(timeout: 5), "Cmd-D showed no launcher")

    app.typeText("repl")
    app.typeKey(.return, modifierFlags: [])
    XCTAssertTrue(waitUntilGone(launcher(in: window), timeout: 10), "Return left the launcher")

    let terminal = window.groups["pane-2"].textViews["terminal"]

    XCTAssertTrue(terminal.waitForExistence(timeout: 20), "the REPL pane never showed a terminal")
    XCTAssertTrue(
      waitFor(terminal, timeout: 40) { $0.contains("repl:1:> ") },
      "the REPL never showed its prompt")

    return terminal
  }

  /// True when some line of the terminal's text is exactly `line`.
  private func hasLine(_ line: String, in text: String) -> Bool {
    text.split(separator: "\n", omittingEmptySubsequences: false).contains {
      $0.trimmingCharacters(in: .whitespaces) == line
    }
  }

  /// Catches a capability restart that widens the live helper, keeps its definitions, or starts
  /// without the chosen capability. The REPL cannot read a file at first. After the restart with
  /// fs-read, the fresh REPL says what it may use, reads the file, and has lost the definition.
  func testARestartWithFsReadStartsAFreshReplThatCanReadAFile() throws {
    let file = scratch + "-capability.txt"

    try Data("twelve bytes".utf8).write(to: URL(fileURLWithPath: file))

    addTeardownBlock { try? FileManager.default.removeItem(atPath: file) }

    let app = launchApp()
    let window = mainWindow(in: app)
    let terminal = openRepl(in: app)

    app.typeText("(def kept 41)\n")
    app.typeText("(length (slurp \"\(file)\"))\n")
    XCTAssertTrue(
      waitFor(terminal, timeout: 20) { $0.contains("sandbox") },
      "the REPL read a file with no capability")
    XCTAssertFalse((terminal.value as? String ?? "").contains("This REPL may use"))

    app.menuBars.menuBarItems["REPL"].click()
    app.menuBars.menuItems["Restart REPL with Capabilities\u{2026}"].click()

    let sheet = window.sheets.firstMatch

    XCTAssertTrue(sheet.waitForExistence(timeout: 5), "the capability sheet never opened")
    XCTAssertTrue(
      sheet.staticTexts.matching(NSPredicate(format: "value CONTAINS 'definition'")).firstMatch
        .exists,
      "the sheet does not warn that definitions are lost")

    let fsRead = sheet.checkBoxes["repl-capability-fs-read"]

    XCTAssertTrue(fsRead.exists, "the sheet offers no fs-read")
    XCTAssertEqual(fsRead.value as? Int, 0, "a capability was selected before the user chose it")

    fsRead.click()
    sheet.buttons["Restart"].click()
    XCTAssertTrue(waitForNoSheet(in: window), "the sheet stayed after Restart")

    let fresh = window.groups["pane-2"].textViews["terminal"]

    XCTAssertTrue(
      waitFor(fresh, timeout: 40) { $0.contains("This REPL may use: fs-read") },
      "the fresh REPL never said what it may use. The pane showed: \(fresh.value as? String ?? "")")
    XCTAssertTrue(
      waitFor(fresh, timeout: 40) { $0.contains("repl:1:> ") }, "the fresh REPL never prompted")

    app.typeText("(length (slurp \"\(file)\"))\n")
    XCTAssertTrue(
      waitFor(fresh, timeout: 20) { self.hasLine("12", in: $0) },
      "the fresh REPL could not read the file. The pane showed: \(fresh.value as? String ?? "")")

    app.typeText("kept\n")
    XCTAssertTrue(
      waitFor(fresh, timeout: 20) { $0.contains("unknown symbol") },
      "the definition survived the restart")
  }
}
