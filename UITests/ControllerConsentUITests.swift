import CryptoKit
import XCTest

/// The startup review and Controllers & Permissions in the real app. A controller package that
/// declares pane control runs from the first pane's terminal with the bundled command. Its review
/// waits in the Pending Requests panel, the panel answers it, and the Controllers & Permissions
/// window shows and revokes the remembered approval.
///
/// The package tests prove each rule of consent and trust. These prove that the panel and the
/// window reach those rules, and that a user can read them. Every capture holds synthetic
/// names only.
@MainActor
final class ControllerConsentUITests: UnitermUITestCase {
  private func attach(_ element: XCUIElement, named name: String) {
    let attachment = XCTAttachment(screenshot: element.screenshot())

    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  /// Writes a package that declares pane control. Its Janet entry prints a line unless the test
  /// gives it another.
  private func writePackage(main source: String = "(print \"consent fixture ran\")\n") throws
    -> String
  {
    let package = scratch + "-consent-package"
    let main = Data(source.utf8)
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

  /// Catches a review that never reaches the panel, a panel that hides the requested power or
  /// offers identity trust for an unsigned package, help that does not say what the offered
  /// choices cover, and Trust This Version that does not let the same version run again without a
  /// review.
  func testThePanelTrustsAVersionThatThenRunsWithoutAsking() throws {
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

    let trustVersion = panel.buttons["pending-requests-trust-version"]

    XCTAssertTrue(trustVersion.waitForExistence(timeout: 5), "the panel offers no version trust")
    XCTAssertFalse(
      panel.buttons["pending-requests-trust-identity"].exists,
      "an unsigned package was offered identity trust")
    XCTAssertTrue(
      waitFor(panel.staticTexts["pending-requests-detail"], timeout: 5) {
        $0.contains("Control panes it may address")
      }, "the panel does not show the requested power")

    XCTAssertTrue(
      panel.buttons["Allow for This Run"].exists, "the review does not name its per-run choice")
    XCTAssertFalse(panel.buttons["Allow for This Session"].exists)

    attach(panel, named: "pending-requests-review")

    let help = panel.buttons["pending-requests-help"]
    let helpText = app.descendants(matching: .staticText)["pending-requests-help-text"]

    XCTAssertTrue(help.exists, "the panel offers no help for the review")
    help.click()
    XCTAssertTrue(
      waitFor(helpText, timeout: 5) {
        $0.contains("Trust This Version remembers them") && !$0.contains("Trust This Identity")
          && $0.contains("Allow for This Run") && !$0.contains("This Session")
      }, "the help does not describe exactly the offered choices")

    attach(panel, named: "pending-requests-help")
    help.click()
    XCTAssertTrue(waitUntilGone(helpText, timeout: 5), "the help button did not close the help")
    trustVersion.click()

    XCTAssertEqual(waitForFile(first), "exit=0\n")
    XCTAssertEqual(
      try String(contentsOfFile: first + ".out", encoding: .utf8), "consent fixture ran\n")
    XCTAssertTrue(waitUntilGone(indicator, timeout: 10), "the indicator stayed after the review")

    let second = try startRun(package, named: "consent-second", in: app)

    XCTAssertEqual(waitForFile(second), "exit=0\n", "the trusted version asked again")
  }

  /// Catches a panel whose Allow Once and Deny do nothing for a startup review, and an Allow Once
  /// that is remembered for the next run.
  func testThePanelAllowsOnceAndDeniesAReview() throws {
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

  /// Catches a question row that does not name the process asking. A run allowed once asks again
  /// for its pane call, and that row's PID column shows the run's PID, as its review row did.
  func testAPaneCallQuestionShowsTheRunsPID() throws {
    let package = try writePackage(
      main: "(import uniterm)\n(print (length (uniterm/list-windows)))\n")
    let app = launchApp()
    let window = mainWindow(in: app)

    defer { try? FileManager.default.removeItem(atPath: package) }

    _ = waitForTerminal(in: app)

    let status = try startRun(package, named: "question-pid", in: app)
    let indicator = window.descendants(matching: .any)["status-window-pending-permissions"]

    XCTAssertTrue(indicator.waitForExistence(timeout: 30), "the window never showed the review")

    let panel = openPendingRequests(in: app)
    let table = panel.tables["pending-requests-table"]
    let review = table.tableRows.firstMatch

    XCTAssertTrue(review.waitForExistence(timeout: 30), "the review never reached the panel")
    review.click()
    panel.buttons["pending-requests-allow-once"].click()

    let question = table.tableRows.containing(
      NSPredicate(format: "value == %@", "Control panes it may address")
    ).firstMatch

    XCTAssertTrue(question.waitForExistence(timeout: 30), "the pane call never asked")

    let pid = question.descendants(matching: .any).matching(
      NSPredicate(format: "value MATCHES %@", "^[0-9]+$")
    ).firstMatch

    attach(panel, named: "pane-call-question")
    XCTAssertTrue(pid.exists, "the question row shows no PID")

    question.click()
    XCTAssertTrue(
      panel.buttons["Allow for This Run"].waitForExistence(timeout: 5),
      "the question does not name its per-run choice")
    attach(panel, named: "pane-call-question-selected")
    panel.buttons["pending-requests-allow-once"].click()

    XCTAssertEqual(waitForFile(status), "exit=0\n")
  }

  /// Catches a plain script's question calling its per-run choice by the connection's name. The
  /// script has no package and no review, so its clipboard question is the first the user sees.
  func testAPlainScriptsQuestionNamesItsRun() throws {
    let script = scratch + "-plain-question.janet"

    try write("(import uniterm)\n(print (get (protect (uniterm/read-clipboard)) 0))\n", to: script)

    let app = launchApp()
    let window = mainWindow(in: app)

    defer { try? FileManager.default.removeItem(atPath: script) }

    _ = waitForTerminal(in: app)

    let status = try startRun(script, named: "plain-question", in: app)
    let indicator = window.descendants(matching: .any)["status-window-pending-permissions"]

    XCTAssertTrue(indicator.waitForExistence(timeout: 30), "the window never showed the question")

    let panel = openPendingRequests(in: app)
    let question = panel.tables["pending-requests-table"].tableRows.firstMatch

    XCTAssertTrue(question.waitForExistence(timeout: 30), "the clipboard call never asked")
    question.click()
    XCTAssertTrue(
      panel.buttons["Allow for This Run"].waitForExistence(timeout: 5),
      "the plain script's question does not name its per-run choice")
    XCTAssertFalse(panel.buttons["Allow for This Connection"].exists)

    attach(panel, named: "plain-script-question")
    panel.buttons["Deny"].click()

    XCTAssertEqual(waitForFile(status), "exit=0\n")
  }

  /// Catches a declared script file whose review never reaches the panel, one that lists powers
  /// the file did not declare or omits one, one titled as a controller, and a remembered file
  /// approval that the window hides or that survives Revoke. The file ran no code until the panel
  /// answered, and runs without a review once its version is trusted.
  func testADeclaredFilesReviewAndApprovalReachThePanelAndTheWindow() throws {
    let script = scratch + "-declared-file.janet"

    try write(
      """
      (declare-permissions {:name "Synthetic Tidy"}
        {:kind :pane-control :version 1}
        {:kind :clipboard-read :version 1})

      (print "declared file ran")

      """, to: script)

    let app = launchApp()
    let window = mainWindow(in: app)

    defer { try? FileManager.default.removeItem(atPath: script) }

    _ = waitForTerminal(in: app)

    let first = try startRun(script, named: "declared-first", in: app)
    let indicator = window.descendants(matching: .any)["status-window-pending-permissions"]

    XCTAssertTrue(indicator.waitForExistence(timeout: 30), "the window never showed the review")

    let panel = openPendingRequests(in: app)
    let row = panel.tables["pending-requests-table"].tableRows.firstMatch

    XCTAssertTrue(row.waitForExistence(timeout: 30), "the review never reached the panel")
    row.click()

    XCTAssertTrue(
      waitFor(panel.staticTexts["pending-requests-detail"], timeout: 5) {
        $0.contains("Script file: Synthetic Tidy") && $0.contains("Control panes it may address")
          && $0.contains("Read the clipboard") && !$0.contains("Replace the clipboard")
      }, "the panel does not show the file and exactly the powers it declared")
    XCTAssertFalse(FileManager.default.fileExists(atPath: first), "the file ran before the answer")

    let trustVersion = panel.buttons["pending-requests-trust-version"]

    XCTAssertTrue(trustVersion.waitForExistence(timeout: 5), "the panel offers no version trust")
    XCTAssertFalse(
      panel.buttons["pending-requests-trust-identity"].exists,
      "an unsigned file was offered identity trust")
    XCTAssertTrue(panel.buttons["Allow for This Run"].exists)

    attach(panel, named: "declared-file-review")
    trustVersion.click()

    XCTAssertEqual(waitForFile(first), "exit=0\n")
    XCTAssertEqual(
      try String(contentsOfFile: first + ".out", encoding: .utf8), "declared file ran\n")

    let second = try startRun(script, named: "declared-second", in: app)

    XCTAssertEqual(waitForFile(second), "exit=0\n", "the trusted file version asked again")

    let controllers = openControllers(in: app)
    let approval = controllers.tables["controllers-table"].tableRows.firstMatch

    XCTAssertTrue(approval.waitForExistence(timeout: 10), "the file approval is not listed")
    approval.click()
    XCTAssertTrue(
      waitFor(controllers.staticTexts["controllers-detail"], timeout: 5) {
        $0.contains("Trusted version of a script file")
      }, "the detail does not name a script file approval")

    attach(controllers, named: "controllers-and-permissions-file-approval")
    controllers.buttons["controllers-revoke"].click()

    XCTAssertTrue(waitUntilGone(approval, timeout: 10), "the file approval stayed after Revoke")
  }

  /// Catches a signed script file whose review omits the signer or hides Trust This Identity, and an
  /// identity approval that the window does not list. The signature is made here with a throwaway
  /// key over the file's bytes under the script-file domain line, as the signer writes it.
  func testASignedFilesReviewOffersTrustThisIdentity() throws {
    let script = scratch + "-signed-file.janet"
    let source = Data(
      """
      (declare-permissions {:id "dev.uniterm.uitest.signed" :name "Synthetic Signed Tidy"}
        {:kind :pane-control :version 1})

      (print "signed file ran")

      """.utf8)
    let key = Curve25519.Signing.PrivateKey()
    let signature = try key.signature(for: Data("uniterm script file 1\n".utf8) + source)
    let fingerprint = SHA256.hash(data: key.publicKey.rawRepresentation)
      .map { String(format: "%02x", $0) }.joined()

    try source.write(to: URL(fileURLWithPath: script))
    try write(
      """
      {
        "format": 1,
        "algorithm": "ed25519",
        "public-key": "\(key.publicKey.rawRepresentation.base64EncodedString())",
        "signature": "\(signature.base64EncodedString())"
      }

      """, to: script + ".sig")

    let app = launchApp()
    let window = mainWindow(in: app)

    defer {
      try? FileManager.default.removeItem(atPath: script)
      try? FileManager.default.removeItem(atPath: script + ".sig")
    }

    _ = waitForTerminal(in: app)

    let first = try startRun(script, named: "signed-first", in: app)
    let indicator = window.descendants(matching: .any)["status-window-pending-permissions"]

    XCTAssertTrue(indicator.waitForExistence(timeout: 30), "the window never showed the review")

    let panel = openPendingRequests(in: app)
    let row = panel.tables["pending-requests-table"].tableRows.firstMatch

    XCTAssertTrue(row.waitForExistence(timeout: 30), "the review never reached the panel")
    row.click()

    XCTAssertTrue(
      waitFor(panel.staticTexts["pending-requests-detail"], timeout: 5) {
        $0.contains("Script file: Synthetic Signed Tidy (dev.uniterm.uitest.signed)")
          && $0.contains("Signed by key: \(fingerprint)")
      }, "the panel does not show the signed file and its signer's key")

    let trustIdentity = panel.buttons["pending-requests-trust-identity"]

    XCTAssertTrue(trustIdentity.waitForExistence(timeout: 5), "a signed file was not offered it")
    attach(panel, named: "signed-file-review")
    trustIdentity.click()

    XCTAssertEqual(waitForFile(first), "exit=0\n")

    let second = try startRun(script, named: "signed-second", in: app)

    XCTAssertEqual(waitForFile(second), "exit=0\n", "the trusted identity asked again")
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

    let trustVersion = panel.buttons["pending-requests-trust-version"]

    XCTAssertTrue(trustVersion.waitForExistence(timeout: 5), "the panel offers no version trust")
    trustVersion.click()
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
