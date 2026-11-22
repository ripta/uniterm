import XCTest

/// Asks a form from a script through the wire, in the running app, as a user's script would.
///
/// The UI test runner is sandboxed, so it cannot connect to the app's socket. The test writes a
/// declared script and a shell script into the scratch folder, types the shell script's path into
/// the terminal, answers the review of the declared file, and then answers the form it opens. The
/// script writes what it received, and the test reads that file. `QuestionsUITests` covers the
/// pane's own behavior without a script.
@MainActor
final class QuestionsWireUITests: UnitermUITestCase {
  private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
    mainWindow(in: app).descendants(matching: .any)[identifier]
  }

  /// Catches a form call that never reaches the real windows. A declared script that holds only
  /// the ask power opens a form and waits. The form opens in a split beside the script's pane with
  /// the declared file named in its header, the script's pane shows the badge, and typing and
  /// Return answer it. The script prints the answer it received.
  func testADeclaredScriptAsksAFormAndReceivesTheAnswer() throws {
    let command = try bundledCommand()
    let app = launchApp()
    let window = mainWindow(in: app)

    _ = waitForTerminal(in: app)

    let fixture = scratch + "-ask.janet"
    let shell = scratch + "-ask.sh"
    let output = scratch + "-ask.out"
    let errors = scratch + "-ask.err"
    let status = scratch + "-ask.status"

    try write(
      """
      (declare-permissions {:name "Synthetic Ask"}
        {:kind :ask-user :version 1})

      (import uniterm)

      (def form
        (uniterm/open-form
          `{"title": "Wire", "items": [{"id": "name", "text": "Name?", "type": "string"}]}`))
      (def result (uniterm/wait-form form))

      (uniterm/discard-form form)
      (print "action " (result :action))
      (print "name " ((result :answers) :name))
      """, to: fixture)

    try write(
      """
      attempts=0
      while [ $attempts -lt 100 ]; do
        "\(command)" run --socket "\(testSocket)" "\(fixture)" > "\(output)" 2> "\(errors)"
        code=$?
        [ $code -ne 69 ] && break
        attempts=$((attempts + 1))
        sleep 0.1
      done
      echo "exit=$code" > "\(status)"
      """, to: shell)

    defer {
      for path in [fixture, shell, output, errors, status] {
        try? FileManager.default.removeItem(atPath: path)
      }
    }

    runInTerminal(shell, in: app)
    answerFirstReview(in: app, pressing: "pending-requests-allow-session")

    let name = element("questions-requester-name", in: app)

    XCTAssertTrue(name.appears(timeout: 30), "the form never opened")
    XCTAssertTrue(
      (name.value as? String)?.hasSuffix("(declared file)") == true,
      "the header says \(String(describing: name.value))")
    XCTAssertTrue(window.groups["pane-2"].exists, "the form did not open in a split")
    XCTAssertTrue(element("pane-asking-1", in: app).appears(timeout: 10), "the asker has no badge")
    XCTAssertTrue(
      waitFor(window.groups["pane-2"], timeout: 10) { $0 == "focused" },
      "the split did not take focus. \(focusReport(app))")

    app.typeText("Ada")
    app.typeKey(.return, modifierFlags: [])

    let result = try XCTUnwrap(waitForFile(status), "the shell never finished the command")
    let errorText = (try? String(contentsOfFile: errors, encoding: .utf8)) ?? ""

    XCTAssertEqual(result, "exit=0\n", errorText)

    let printed = try String(contentsOfFile: output, encoding: .utf8)

    XCTAssertEqual(printed.split(separator: "\n").map(String.init), ["action ok", "name Ada"])
    XCTAssertTrue(waitUntilGone(element("pane-asking-1", in: app)), "the badge outlived the form")
  }
}
