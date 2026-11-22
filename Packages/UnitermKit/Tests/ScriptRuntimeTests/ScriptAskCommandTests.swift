import Foundation
import ScriptWire
import XCTest

@testable import ScriptRuntime

/// What `uniterm ask` does before it connects and after the app answers: how it reads its flags,
/// the form each shorthand sends, how it prints a result, and the exit status of every failure.
/// It cannot prove the app's side or the real process, which `ScriptAskRunTests` runs.
final class ScriptAskCommandTests: XCTestCase {
  private struct Refused: Error {
    let arguments: [String]
  }

  private func invocation(_ arguments: [String]) throws -> ScriptAskCommand.Invocation {
    guard case .ask(let parsed) = ScriptAskCommand.parse(arguments) else {
      throw Refused(arguments: arguments)
    }

    return parsed
  }

  private func spec(_ arguments: [String]) throws -> NSDictionary {
    let built = try XCTUnwrap(ScriptAskCommand.spec(for: try invocation(arguments)))

    return try XCTUnwrap(
      try JSONSerialization.jsonObject(with: Data(built.text.utf8)) as? NSDictionary)
  }

  private func question(_ arguments: [String]) throws -> NSDictionary {
    try XCTUnwrap((try spec(arguments)["items"] as? [NSDictionary])?.first)
  }

  // MARK: Flags

  /// Catches a flag that is read as a prompt, a prompt that is read as a flag, and a flag that
  /// works on a kind it does not belong to. Each kind takes only its own flags.
  func testEachKindTakesItsOwnFlagsAndWordsOnly() throws {
    let text = try invocation(["text", "--default", "main", "--pattern", "^a$", "Branch?"])

    XCTAssertEqual(text.defaultText, "main")
    XCTAssertEqual(text.pattern, "^a$")
    XCTAssertEqual(text.prompt, "Branch?")

    let choose = try invocation(["choose", "--multiple", "Which?", "a", "b"])

    XCTAssertTrue(choose.multiple)
    XCTAssertEqual(choose.choices, ["a", "b"])

    let number = try invocation(["number", "--integer", "--min", "-1", "--max", "2.5", "N?"])

    XCTAssertEqual([number.minimum, number.maximum], ["-1", "2.5"])

    let file = try invocation(["file", "--save", "--type", "public.json", "--type", "a.b", "File?"])

    XCTAssertEqual(file.mode, "save")
    XCTAssertEqual(file.types, ["public.json", "a.b"])
    XCTAssertEqual(try invocation(["file", "--directory", "--", "-odd"]).prompt, "-odd")
    XCTAssertTrue(try invocation(["color", "--json", "--socket", "/s", "C?"]).json)
    XCTAssertEqual(ScriptAskCommand.parse(["--help"]), .help)
    XCTAssertEqual(ScriptAskCommand.parse(["text", "-h"]), .help)

    let bad: [[String]] = [
      [], ["nope"], ["confirm"], ["confirm", "a", "b"], ["confirm", "--multiple", "x"],
      ["text", "--default"], ["choose", "Which?"], ["choose", "--multiple", "--other", "x", "a"],
      ["number", "--min", "abc", "N?"], ["number", "--min", "1; drop", "N?"],
      ["file", "--directory", "--save", "x"], ["form", "extra"], ["form", "--json"],
      ["text", "--socket"],
    ]

    for arguments in bad {
      guard case .usage = ScriptAskCommand.parse(arguments) else {
        return XCTFail("\(arguments) was accepted")
      }
    }
  }

  /// Catches a number flag that carries anything but a number into the form. The literal is
  /// written as typed, so only the JSON number grammar may pass.
  func testOnlyJSONNumbersPassAsLimits() {
    for good in ["0", "-1", "12", "0.5", "-0.25", "1e3", "2E-7", "10.0e+2"] {
      XCTAssertTrue(ScriptAskSpec.isJSONNumber(good), good)
    }

    for bad in ["", "-", "01", ".5", "5.", "1e", "+1", "0x10", "1 ", "1,2", "NaN", "1}"] {
      XCTAssertFalse(ScriptAskSpec.isJSONNumber(bad), bad)
    }
  }

  // MARK: Forms

  /// Catches a shorthand that asks another question than its flags describe. Each kind's form is
  /// pinned, so the app's strict reader sees what the user typed and nothing else.
  func testEachShorthandSendsItsQuestionAsAForm() throws {
    let confirm = try spec(["confirm", "Delete 3 files?"])

    XCTAssertEqual(
      confirm["items"] as? [NSDictionary],
      [["block": "paragraph", "text": "Delete 3 files?"]] as [NSDictionary])
    XCTAssertEqual(
      confirm["actions"] as? [NSDictionary],
      [
        ["id": "yes", "label": "Yes", "role": "primary"],
        ["id": "no", "label": "No", "role": "cancel"],
      ] as [NSDictionary])

    XCTAssertEqual(
      try question(["text", "--default", "main", "--pattern", "^[a-z]+$", "Branch?"]),
      [
        "id": "answer", "text": "Branch?", "type": "string", "required": true,
        "default": "main", "validate": ["pattern": "^[a-z]+$"],
      ] as NSDictionary)

    XCTAssertEqual(
      try question(["choose", "--other", "Region?", "us-east", "eu-west"]),
      [
        "id": "answer", "text": "Region?", "type": "choice", "required": true,
        "choices": ["us-east", "eu-west"], "other": true,
      ] as NSDictionary)

    XCTAssertEqual(
      try question(["choose", "--multiple", "Which?", "a", "b"])["type"] as? String, "multi")

    XCTAssertEqual(
      try question(["number", "--integer", "--min", "1", "--max", "20", "Replicas?"]),
      [
        "id": "answer", "text": "Replicas?", "type": "integer", "required": true,
        "validate": ["minimum": 1, "maximum": 20],
      ] as NSDictionary)

    XCTAssertEqual(try question(["number", "N?"])["type"] as? String, "number")
    XCTAssertNil(try question(["number", "N?"])["validate"])
    XCTAssertEqual(try question(["color", "C?"])["type"] as? String, "color")

    let file = try question(["file", "--directory", "--type", "public.json", "Pick"])

    XCTAssertEqual(file["type"] as? String, "file")
    XCTAssertEqual(file["mode"] as? String, "directory")
    XCTAssertEqual(file["types"] as? [String], ["public.json"])
    XCTAssertNil(try question(["file", "Pick"])["mode"])
  }

  /// Catches text that breaks out of its string in the form. A prompt with quotes, a backslash, a
  /// newline, and a control character reads back as the same text.
  func testPromptTextIsEscapedIntoTheForm() throws {
    let prompt = "say \"hi\" \\ then\nnew\ttab \u{1} \u{2028} é 😀"

    XCTAssertEqual(try question(["color", prompt])["text"] as? String, prompt)
  }

  // MARK: Output

  /// Catches a result that prints as something a script cannot split. A string is one line, a list
  /// is a line each, a number has no stray fraction, and JSON escapes what it must.
  func testValuesPrintAsLinesOrJSON() {
    XCTAssertEqual(ScriptAskOutput.lines(of: .string("a b")), ["a b"])
    XCTAssertEqual(ScriptAskOutput.lines(of: .array([.string("a"), .string("b")])), ["a", "b"])
    XCTAssertEqual(ScriptAskOutput.lines(of: .integer(7)), ["7"])
    XCTAssertEqual(ScriptAskOutput.lines(of: .number(-3)), ["-3"])
    XCTAssertEqual(ScriptAskOutput.lines(of: .number(0.1)), ["0.1"])
    XCTAssertEqual(ScriptAskOutput.lines(of: .null), [])

    XCTAssertEqual(
      ScriptAskOutput.json(
        .record([
          "b": .array([.string("x\ny"), .number(2.5), .null]), "a": .bool(true), "c": .integer(3),
        ])),
      #"{"a":true,"b":["x\ny",2.5,null],"c":3}"#)
    XCTAssertEqual(ScriptAskOutput.json(.string("\u{1}\"")), #""\u0001\"""#)
  }

  /// Catches a result read as another outcome. Each shape the app sends reads as its own outcome,
  /// and anything else is refused.
  func testAResultReadsAsItsOutcome() throws {
    XCTAssertEqual(
      try ScriptAskOutput.result(
        of: .record([
          "form": .integer(1), "submission": .integer(1), "action": .string("go"),
          "answers": .record(["answer": .string("x")]),
        ])),
      .answered(action: "go", answers: ["answer": .string("x")]))
    XCTAssertEqual(
      try ScriptAskOutput.result(
        of: .record(["outcome": .string("cancelled"), "action": .string("no")])), .cancelled)
    XCTAssertEqual(
      try ScriptAskOutput.result(of: .record(["outcome": .string("dismissed")])), .dismissed)

    for bad: ScriptValue in [
      .null, .record(["outcome": .string("other")]), .record(["action": .string("x")]),
    ] {
      XCTAssertThrowsError(try ScriptAskOutput.result(of: bad))
    }
  }

  /// Catches a failure kind that exits as an answer or as a success, or that has no code of its
  /// own. Every kind maps to a documented status other than 0 and 1.
  func testEveryFailureKindMapsToADocumentedStatusOtherThanZeroAndOne() {
    let expected: [ScriptFailureKind: Int32] = [
      .failed: 69, .notFound: 4, .ended: 4, .unsupported: 70, .replyLost: 74,
      .badArgument: 65, .refused: 77, .busy: 75,
    ]

    XCTAssertEqual(Set(expected.keys), Set(ScriptFailureKind.allCases), "a kind has no pinned code")

    for (kind, status) in expected {
      XCTAssertEqual(ScriptAskOutput.status(for: kind), status, "\(kind)")
      XCTAssertFalse([0, 1].contains(status), "\(kind)")
    }
  }

  /// Catches the command running from outside the bundle. The test process is not the bundle's
  /// command, so the entry point refuses with 78 before it reads a flag or connects.
  func testTheCommandOutsideTheBundleExitsNotTheBundlesCommand() {
    XCTAssertEqual(
      ScriptHelperMain.run(
        arguments: ["uniterm", "ask", "confirm", "x"], identity: .bundle, environment: [:]), 78)
  }
}
