import Foundation
import QuestionForm
import XCTest

@testable import QuestionsApplet

/// Proves the timing rules of "Validation" and the button rules of "Buttons" on the session that
/// the form's views report to. It cannot prove what a view draws, which the UI tests look at.
@MainActor
final class FormSessionTests: XCTestCase {
  private func session(_ json: String) throws -> FormSession {
    FormSession(spec: try FormSpecReader.decode(Data(json.utf8)))
  }

  private let form = """
    {"items": [
      {"id": "name", "text": "Name?", "type": "string", "required": true,
       "validate": {"minLength": 3}},
      {"id": "count", "text": "How many?", "type": "integer", "validate": {"minimum": 1}}],
     "actions": [
      {"id": "go", "label": "Go", "role": "primary"},
      {"id": "skip", "label": "Skip", "validates": false},
      {"id": "stop", "label": "Stop", "role": "cancel"}]}
    """

  /// Catches an error that shows while the user types, which "Validation" forbids. The field is
  /// invalid from the first keystroke, and its error stays hidden until the user leaves it.
  func testAnErrorShowsOnlyAfterTheUserLeavesTheField() throws {
    let session = try session(form)

    XCTAssertNil(session.shownError(for: "name"))

    session.set(.text("ab"), for: "name")

    XCTAssertEqual(session.states["name"], .invalid("Use at least 3 characters."))
    XCTAssertNil(session.shownError(for: "name"))

    session.leave("name")

    XCTAssertEqual(session.shownError(for: "name"), "Use at least 3 characters.")
  }

  /// Catches a shown error that outlives the fix, and one that comes back while the user types a
  /// later mistake, since an error is for fields the user left.
  func testAShownErrorClearsAtOnceAndDoesNotReturnWhileTyping() throws {
    let session = try session(form)

    session.set(.text("ab"), for: "name")
    session.leave("name")
    session.set(.text("abc"), for: "name")

    XCTAssertNil(session.shownError(for: "name"))

    session.set(.text("a"), for: "name")

    XCTAssertNil(session.shownError(for: "name"))
  }

  /// Catches an error that shows while the user types into a field they left earlier. Leaving a
  /// valid field reveals nothing, so a later mistake stays hidden until the user leaves again.
  func testLeavingAValidFieldDoesNotRevealALaterMistake() throws {
    let session = try session(form)

    session.set(.text("abc"), for: "name")
    session.leave("name")
    session.set(.text("a"), for: "name")

    XCTAssertNil(session.shownError(for: "name"))

    session.leave("name")

    XCTAssertEqual(session.shownError(for: "name"), "Use at least 3 characters.")
  }

  /// Catches a try to submit that reveals the valid fields too, which would show their next
  /// mistake while the user fixes another field.
  func testATryToSubmitRevealsOnlyTheFieldsThatFailed() throws {
    let session = try session(form)

    session.set(.text("abc"), for: "name")
    session.set(.number("0"), for: "count")

    XCTAssertEqual(session.press(session.spec.buttons[0]), .blocked(firstError: "count"))

    session.set(.text("a"), for: "name")

    XCTAssertNil(session.shownError(for: "name"))
    XCTAssertEqual(session.shownError(for: "count"), "Use 1 or more.")
  }

  /// Catches a validating button that enables before every required question is answered and every
  /// field passes, and a button that does not validate that waits for them.
  func testAValidatingButtonWaitsForTheWholeForm() throws {
    let session = try session(form)
    let go = session.spec.buttons[0]
    let skip = session.spec.buttons[1]
    let stop = session.spec.buttons[2]

    XCTAssertFalse(session.isEnabled(go))
    XCTAssertTrue(session.isEnabled(skip))
    XCTAssertTrue(session.isEnabled(stop))

    session.set(.text("abc"), for: "name")

    XCTAssertTrue(session.isEnabled(go))

    session.set(.number("0"), for: "count")

    XCTAssertFalse(session.isEnabled(go))

    session.set(.number("2"), for: "count")

    XCTAssertTrue(session.isEnabled(go))
  }

  /// Catches a try to submit that shows only one error or none, and one that names the wrong
  /// field to focus. It shows every error and names the first, in the form's order.
  func testATryToSubmitShowsEveryErrorAndNamesTheFirst() throws {
    let session = try session(form)

    session.set(.number("0"), for: "count")

    let attempt = session.press(session.spec.buttons[0])

    XCTAssertEqual(attempt, .blocked(firstError: "name"))
    XCTAssertEqual(session.shownError(for: "name"), FormChecker.required)
    XCTAssertEqual(session.shownError(for: "count"), "Use 1 or more.")
  }

  /// Catches the three ways a form ends: a valid press submits, a button that does not validate
  /// submits whatever is filled in, and cancel never validates and carries no answers.
  func testEachButtonRoleEndsTheFormItsOwnWay() throws {
    let session = try session(form)

    XCTAssertEqual(
      session.press(session.spec.buttons[2]), .finished(.cancelled(action: "stop")))

    session.set(.text("a"), for: "name")

    XCTAssertEqual(
      session.press(session.spec.buttons[1]),
      .finished(
        .submitted(
          submission: 1, action: "skip",
          answers: ["name": .text("a"), "count": .unanswered])))

    session.set(.text("abc"), for: "name")

    guard
      case .finished(.submitted(_, let action, let answers)) = session.press(
        session.spec.buttons[0])
    else { return XCTFail("a valid form did not submit") }

    XCTAssertEqual(action, "go")
    XCTAssertEqual(answers["name"], .text("abc"))
  }

  func testDefaultsFillTheAnswersAndPlaceholdersDoNot() throws {
    let session = try session(
      """
      {"items": [
        {"id": "a", "text": "A?", "type": "string", "default": "kept", "placeholder": "hint"},
        {"id": "b", "text": "B?", "type": "string", "placeholder": "hint only"},
        {"id": "c", "text": "C?", "type": "boolean"},
        {"id": "d", "text": "D?", "type": "color", "default": "#112233"}]}
      """)

    XCTAssertEqual(session.answer(for: "a"), .text("kept"))
    XCTAssertEqual(session.answer(for: "b"), .unanswered)
    XCTAssertEqual(session.answer(for: "c"), .unanswered)
    XCTAssertEqual(session.answer(for: "d"), .text("#112233ff"))
  }

  /// Catches a validating button that enables while a `pattern` check still runs, and one that
  /// stays disabled after the check passes. The check runs off the main thread, so the test waits
  /// for its delivery.
  func testAPatternCheckKeepsTheButtonDisabledUntilItPasses() async throws {
    let session = try session(
      """
      {"items": [{"id": "p", "text": "P?", "type": "string", "validate": {"pattern": "^[a-z]+$"}}]}
      """)

    let button = session.spec.buttons[0]
    let done = expectation(description: "the check ends")

    session.onChange = { [unowned session] in
      if session.states["p"] == .valid { done.fulfill() }
    }

    session.set(.text("abc"), for: "p")

    XCTAssertFalse(session.isEnabled(button))

    await fulfillment(of: [done], timeout: 5)

    XCTAssertTrue(session.isEnabled(button))
  }
}
