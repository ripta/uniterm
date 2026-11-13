import CryptoKit
import XCTest

/// The startup review and Controllers & Permissions in the real app. A controller package that
/// declares pane control runs from the first pane's terminal with the bundled command. Its review
/// waits in the Pending Requests panel, the review sheet answers it, and the Controllers &
/// Permissions window shows and revokes the remembered approval.
///
/// The package tests prove each rule of consent and trust. These prove that the panel, the sheet,
/// and the window reach those rules, and that a user can read them. Every capture holds synthetic
/// names only.
@MainActor
final class ControllerConsentUITests: UnitermUITestCase {
  private func attach(_ element: XCUIElement, named name: String) {
    let attachment = XCTAttachment(screenshot: element.screenshot())

    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  /// Writes a package whose Janet entry prints a line, and declares pane control.
  private func writePackage() throws -> String {
    let package = scratch + "-consent-package"
    let main = Data("(print \"consent fixture ran\")\n".utf8)
    let digest = SHA256.hash(data: main).map { String(format: "%02x", $0) }.joined()

    try FileManager.default.createDirectory(atPath: package, withIntermediateDirectories: true)
    try main.write(to: URL(fileURLWithPath: package + "/main.janet"))
    try write(
      """
      {
        "format": 2,
        "id": "dev.uniterm.uitest.consent",
        "name": "Synthetic Consent Fixture",
        "entry": {"kind": "janet", "path": "main.janet"},
        "files": {"main.janet": "sha256:\(digest)"},
        "permissions": [{"kind": "pane-control", "version": 1}]
      }

      """, to: package + "/controller.json")

    return package
  }

  /// Runs the package from the terminal and returns the status file the shell writes.
  private func startRun(_ package: String, named name: String, in app: XCUIApplication) throws
    -> String
  {
    let command = try bundledCommand()
    let shell = scratch + "-\(name).sh"
    let status = scratch + "-\(name).status"

    try write(
      """
      attempts=0
      while [ $attempts -lt 100 ]; do
        "\(command)" run --socket "\(testSocket)" "\(package)" > "\(status).out" 2> "\(status).err"
        code=$?
        [ $code -ne 69 ] && break
        attempts=$((attempts + 1))
        sleep 0.1
      done
      echo "exit=$code" > "\(status)"
      """, to: shell)

    addTeardownBlock {
      for path in [shell, status, status + ".out", status + ".err"] {
        try? FileManager.default.removeItem(atPath: path)
      }
    }

    try focusTerminal(in: app)
    runInTerminal(shell, in: app)

    return status
  }

  /// Gives the main window's terminal the keys. A panel the test opened would take them
  /// otherwise, and every key it cannot use beeps. The panels can cover the terminal, so they
  /// close first, and the test stops rather than type anywhere else.
  ///
  /// Controllers & Permissions opens after Pending Requests and can cover its close button, so the
  /// panels close in the reverse of the order the tests open them. A close button that something
  /// still covers stops the test instead of clicking whatever lies on top.
  private func focusTerminal(in app: XCUIApplication) throws {
    for identifier in ["controllers-window", "pending-requests-window"] {
      let panel = app.windows[identifier]

      guard panel.exists else { continue }

      let close = panel.buttons[XCUIIdentifierCloseWindow]

      guard close.isHittable else {
        XCTFail("\(identifier)'s close button is covered")

        throw TerminalNotFocused()
      }

      close.click()

      guard waitUntilGone(panel, timeout: 5) else {
        XCTFail("\(identifier) did not close")

        throw TerminalNotFocused()
      }
    }

    let terminal = mainWindow(in: app).textViews["terminal"]

    terminal.click()

    let focused = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: terminal)

    guard XCTWaiter().wait(for: [focused], timeout: 5) == .completed else {
      XCTFail("the terminal did not take the keys, so typing would beep")

      throw TerminalNotFocused()
    }
  }

  private func openPendingRequests(in app: XCUIApplication) -> XCUIElement {
    app.menuBars.menuBarItems["Window"].click()
    app.menuBars.menuItems["Pending Requests\u{2026}"].click()

    let panel = app.windows["pending-requests-window"]

    XCTAssertTrue(panel.waitForExistence(timeout: 5), "the Pending Requests panel never opened")

    return panel
  }

  private func openControllers(in app: XCUIApplication) -> XCUIElement {
    app.menuBars.menuBarItems["Window"].click()
    app.menuBars.menuItems["Controllers & Permissions\u{2026}"].click()

    let window = app.windows["controllers-window"]

    XCTAssertTrue(window.waitForExistence(timeout: 5), "Controllers & Permissions never opened")

    return window
  }

  /// Catches a review that never reaches the panel, a sheet that hides the requested power or
  /// offers identity trust for an unsigned package, and Trust This Version that does not let the
  /// same version run again without a review.
  func testTheReviewSheetTrustsAVersionThatThenRunsWithoutAsking() throws {
    let package = try writePackage()
    let app = launchApp()
    let window = mainWindow(in: app)

    defer { try? FileManager.default.removeItem(atPath: package) }

    _ = waitForTerminal(in: app)

    let first = try startRun(package, named: "consent-first", in: app)
    let indicator = window.descendants(matching: .any)["status-window-pending-permissions"]

    XCTAssertTrue(indicator.waitForExistence(timeout: 30), "the window never showed the review")

    let panel = openPendingRequests(in: app)
    let row = panel.tables["pending-requests-table"].tableRows.firstMatch

    XCTAssertTrue(row.waitForExistence(timeout: 30), "the review never reached the panel")
    row.click()
    panel.buttons["pending-requests-review"].click()

    let sheet = panel.sheets.firstMatch

    XCTAssertTrue(sheet.waitForExistence(timeout: 5), "Review showed no sheet")
    XCTAssertTrue(sheet.buttons["controller-review-version"].exists)
    XCTAssertFalse(
      sheet.buttons["controller-review-identity"].exists,
      "an unsigned package was offered identity trust")
    XCTAssertTrue(
      sheet.staticTexts.allElementsBoundByIndex.contains {
        ($0.value.map { "\($0)" } ?? "").contains("Control panes it may address")
          || $0.label.contains("Control panes it may address")
      }, "the sheet does not show the requested power")

    attach(sheet, named: "controller-review-sheet")
    sheet.buttons["controller-review-version"].click()

    XCTAssertEqual(waitForFile(first), "exit=0\n")
    XCTAssertEqual(
      try String(contentsOfFile: first + ".out", encoding: .utf8), "consent fixture ran\n")
    XCTAssertTrue(waitUntilGone(indicator, timeout: 10), "the indicator stayed after the review")

    let second = try startRun(package, named: "consent-second", in: app)

    XCTAssertEqual(waitForFile(second), "exit=0\n", "the trusted version asked again")
  }

  /// Catches a panel whose Allow Once and Deny do nothing for a startup review, so that only the
  /// sheet could answer it, and an Allow Once that is remembered for the next run.
  func testThePanelAnswersAReviewWithoutTheSheet() throws {
    let package = try writePackage()
    let app = launchApp()
    let window = mainWindow(in: app)

    defer { try? FileManager.default.removeItem(atPath: package) }

    _ = waitForTerminal(in: app)

    let first = try startRun(package, named: "panel-once", in: app)
    let indicator = window.descendants(matching: .any)["status-window-pending-permissions"]

    XCTAssertTrue(indicator.waitForExistence(timeout: 30), "the window never showed the review")

    let panel = openPendingRequests(in: app)
    let row = panel.tables["pending-requests-table"].tableRows.firstMatch

    XCTAssertTrue(row.waitForExistence(timeout: 30), "the review never reached the panel")
    row.click()
    panel.buttons["pending-requests-allow-once"].click()

    XCTAssertFalse(panel.sheets.firstMatch.exists, "Allow Once opened the sheet")
    XCTAssertEqual(waitForFile(first), "exit=0\n")
    XCTAssertEqual(
      try String(contentsOfFile: first + ".out", encoding: .utf8), "consent fixture ran\n")

    let second = try startRun(package, named: "panel-deny", in: app)

    XCTAssertTrue(
      indicator.waitForExistence(timeout: 30), "a run allowed once was remembered for the next")

    let open = openPendingRequests(in: app)
    let next = open.tables["pending-requests-table"].tableRows.firstMatch

    XCTAssertTrue(next.waitForExistence(timeout: 30), "the second review never reached the panel")
    next.click()
    open.buttons["Deny"].click()

    XCTAssertNotEqual(waitForFile(second), "exit=0\n", "a denied review still ran")
  }

  /// Catches a Controllers & Permissions window that hides a remembered approval, and a Revoke
  /// that leaves it covering the next run.
  func testControllersAndPermissionsShowsAndRevokesTheApproval() throws {
    let package = try writePackage()
    let app = launchApp()
    let window = mainWindow(in: app)

    defer { try? FileManager.default.removeItem(atPath: package) }

    _ = waitForTerminal(in: app)

    let first = try startRun(package, named: "consent-trust", in: app)
    let panel = openPendingRequests(in: app)
    let row = panel.tables["pending-requests-table"].tableRows.firstMatch

    XCTAssertTrue(row.waitForExistence(timeout: 30), "the review never reached the panel")
    row.click()
    panel.buttons["pending-requests-review"].click()

    let sheet = panel.sheets.firstMatch

    XCTAssertTrue(sheet.waitForExistence(timeout: 5))
    sheet.buttons["controller-review-version"].click()
    XCTAssertEqual(waitForFile(first), "exit=0\n")

    let controllers = openControllers(in: app)
    let approval = controllers.tables["controllers-table"].tableRows.firstMatch

    XCTAssertTrue(approval.waitForExistence(timeout: 10), "the approval is not listed")
    approval.click()

    let detail = controllers.staticTexts["controllers-detail"]

    XCTAssertTrue(
      waitFor(detail, timeout: 5) { $0.contains("Trusted version of dev.uniterm.uitest.consent") },
      "the detail does not name the selector")

    attach(controllers, named: "controllers-and-permissions")
    controllers.buttons["controllers-revoke"].click()

    XCTAssertTrue(waitUntilGone(approval, timeout: 10), "the approval stayed after Revoke")

    _ = try startRun(package, named: "consent-after-revoke", in: app)

    let indicator = window.descendants(matching: .any)["status-window-pending-permissions"]

    XCTAssertTrue(indicator.waitForExistence(timeout: 30), "a revoked approval still covered a run")
  }
}

/// The terminal could not be given the keys, so the test stops before it types.
private struct TerminalNotFocused: Error {}
