import Foundation
import ScriptWire
import XCTest

@testable import QuestionForm

/// Proves each validation keyword, the required rule, and the shared error shape through the
/// spec reader and `FormChecker`, the way a form's answers meet them. It does not time patterns,
/// which `PatternTests` holds.
final class FormValidationTests: XCTestCase {
  private func question(_ type: String, _ validate: String, extra: String = "") throws
    -> FormQuestion
  {
    let rule = validate.isEmpty ? "" : #", "validate": {\#(validate)}"#

    return try decodeSpec(oneQuestion(#""type": "\#(type)"\#(extra)\#(rule)"#)).questions[0]
  }

  private func message(_ question: FormQuestion, _ answer: FormAnswer) -> String? {
    switch FormChecker.verdict(question, answer) {
    case .invalid(let text): return text
    case .valid: return nil
    case .needsPattern: return "needs pattern"
    }
  }

  /// Catches a keyword that is not enforced, or is enforced at the wrong edge.
  func testEachKeywordAcceptsAndRefusesAtItsEdge() throws {
    struct Case {
      let type: String
      let validate: String
      let extra: String
      let good: [FormAnswer]
      let bad: [FormAnswer]
    }

    let cases = [
      Case(
        type: "string", validate: #""minLength": 2"#, extra: "", good: [.text("ab")],
        bad: [.text("a")]),
      Case(
        type: "string", validate: #""maxLength": 2"#, extra: "", good: [.text("ab")],
        bad: [.text("abc")]),
      Case(
        type: "integer", validate: #""minimum": 3"#, extra: "", good: [.number("3"), .number("4")],
        bad: [.number("2")]),
      Case(
        type: "integer", validate: #""maximum": 3"#, extra: "", good: [.number("3")],
        bad: [.number("4")]),
      Case(
        type: "number", validate: #""exclusiveMinimum": 0"#, extra: "", good: [.number("0.001")],
        bad: [.number("0"), .number("-1")]),
      Case(
        type: "number", validate: #""exclusiveMaximum": 1.5"#, extra: "", good: [.number("1.4999")],
        bad: [.number("1.5")]),
      Case(
        type: "number", validate: #""multipleOf": 0.1"#, extra: "",
        good: [.number("0.3"), .number("0.7"), .number("-1.2")], bad: [.number("0.35")]),
      Case(
        type: "integer", validate: #""multipleOf": 5"#, extra: "",
        good: [.number("10"), .number("0")], bad: [.number("12")]),
      Case(
        type: "multi", validate: #""minItems": 2"#, extra: #", "choices": ["a", "b", "c"]"#,
        good: [.list(["a", "b"])], bad: [.list(["a"])]),
      Case(
        type: "multi", validate: #""maxItems": 1"#, extra: #", "choices": ["a", "b", "c"]"#,
        good: [.list(["a"])], bad: [.list(["a", "b"])]),
      Case(
        type: "file", validate: #""minItems": 2, "maxItems": 3"#, extra: #", "multiple": true"#,
        good: [.list(["/a", "/b"])], bad: [.list(["/a"]), .list(["/a", "/b", "/c", "/d"])]),
    ]

    for item in cases {
      let question = try question(item.type, item.validate, extra: item.extra)

      for answer in item.good {
        XCTAssertNil(message(question, answer), "\(item.validate) \(answer)")
      }

      for answer in item.bad {
        XCTAssertNotNil(message(question, answer), "\(item.validate) \(answer)")
      }
    }
  }

  /// Catches a double-based comparison. 0.3 is not a multiple of 0.1 in binary floating point.
  func testDecimalsCompareExactly() throws {
    XCTAssertNotEqual(0.3.truncatingRemainder(dividingBy: 0.1), 0)

    let multiple = try question("number", #""multipleOf": 0.1"#)

    XCTAssertNil(message(multiple, .number("0.3")))

    let bounded = try question("number", #""minimum": 0.1, "maximum": 0.3"#)

    XCTAssertNil(message(bounded, .number("0.1")))
    XCTAssertNil(message(bounded, .number("0.3")))
    XCTAssertNotNil(message(bounded, .number("0.30000000000000001")))
  }

  func testNumbersMustBeNumbersAndIntegersWhole() throws {
    let integer = try question("integer", "")

    for text in ["abc", "1.5", "1e2x", "", "+1", "01", ".5", "9007199254740992"] where !text.isEmpty
    {
      XCTAssertNotNil(message(integer, .number(text)), text)
    }

    XCTAssertNil(message(integer, .number("100")))
    XCTAssertNil(message(integer, .number("1e2")))
    XCTAssertNil(message(integer, .number("-9007199254740991")))
  }

  /// Catches counting UTF-16 units or grapheme clusters. JSON Schema counts code points: "e" with
  /// a combining acute is two, and an emoji outside the BMP is one.
  func testLengthCountsCodePoints() throws {
    let text = "e\u{301}\u{1F600}"

    XCTAssertEqual(text.unicodeScalars.count, 3)
    XCTAssertEqual(text.count, 2)
    XCTAssertEqual(text.utf16.count, 4)

    let exact = try question("string", #""minLength": 3, "maxLength": 3"#)

    XCTAssertNil(message(exact, .text(text)))
    XCTAssertNotNil(message(exact, .text("e\u{301}")))
    XCTAssertNotNil(message(exact, .text(text + "x")))
  }

  func testRequiredAndOptionalAnswers() throws {
    for type in ["boolean", "string", "integer", "color"] {
      let optional = try decodeSpec(oneQuestion(#""type": "\#(type)""#)).questions[0]
      let required = try decodeSpec(oneQuestion(#""type": "\#(type)", "required": true"#))
        .questions[0]

      XCTAssertNil(message(optional, .unanswered), type)
      XCTAssertEqual(message(required, .unanswered), FormChecker.required, type)
    }

    let text = try decodeSpec(oneQuestion(#""type": "text", "required": true"#)).questions[0]

    XCTAssertEqual(message(text, .text("")), FormChecker.required)

    let multi = try decodeSpec(oneQuestion(#""type": "multi", "choices": ["a"], "required": true"#))
      .questions[0]

    XCTAssertEqual(message(multi, .list([])), FormChecker.required)

    let optionalLength = try question("string", #""minLength": 3"#)

    XCTAssertNil(message(optionalLength, .unanswered))
    XCTAssertNil(message(optionalLength, .text("")))
  }

  func testChoiceColorFileAndHardCaps() throws {
    let choice = try decodeSpec(oneQuestion(#""type": "choice", "choices": ["a", "b"]"#)).questions[
      0]
    let other = try decodeSpec(oneQuestion(#""type": "choice", "choices": ["a"], "other": true"#))
      .questions[0]

    XCTAssertNil(message(choice, .text("a")))
    XCTAssertNotNil(message(choice, .text("c")))
    XCTAssertNil(message(other, .text("anything")))
    XCTAssertNotNil(
      message(other, .text(String(repeating: "x", count: FormLimits.maxOtherBytes + 1))))

    let color = try question("color", "")

    XCTAssertNil(message(color, .text("#aabbcc")))
    XCTAssertNil(message(color, .text("#AABBCC80")))
    XCTAssertNotNil(message(color, .text("#abc")))
    XCTAssertEqual(FormChecker.normalizedColor("#AABBCC"), "#aabbccff")

    let multi = try decodeSpec(oneQuestion(#""type": "multi", "choices": ["a", "b"]"#)).questions[0]

    XCTAssertNotNil(message(multi, .list(["a", "a"])))
    XCTAssertNotNil(message(multi, .list(["z"])))

    let file = try question("file", "", extra: #", "mode": "directory""#)

    XCTAssertNil(message(file, .text("/tmp")))
    XCTAssertNotNil(
      message(file, .text(String(repeating: "x", count: FormLimits.maxPathBytes + 1))))

    let single = try question("string", "")

    XCTAssertNotNil(
      message(single, .text(String(repeating: "x", count: FormLimits.maxStringAnswerBytes + 1))))
    XCTAssertNotNil(message(single, .text("two\nlines")))

    let limited = try question("text", #""maxLength": 10"#)

    XCTAssertEqual(limited.answerByteLimit, 40)
    XCTAssertNotNil(message(limited, .text(String(repeating: "😀", count: 11))))
  }

  /// Catches an error that is not keyed by question id, which is the shape a later script-side
  /// rejection shares.
  func testErrorShape() throws {
    let spec = try decodeSpec(
      #"{"items": [{"id": "n", "text": "t", "type": "integer", "validate": {"minimum": 5}}, {"id": "s", "text": "t", "type": "string", "required": true}, {"id": "ok", "text": "t", "type": "boolean"}]}"#
    )

    let errors = FormChecker.check(spec, answers: ["n": .number("2")])

    XCTAssertEqual(Set(errors.messages.keys), ["n", "s"])
    XCTAssertEqual(
      errors.scriptValue,
      .record([
        "errors": .record(["n": .string(errors.messages["n"]!), "s": .string(FormChecker.required)])
      ]))
    XCTAssertTrue(FormChecker.check(spec, answers: ["n": .number("9"), "s": .text("x")]).isEmpty)
  }

  func testAnswerValues() throws {
    let spec = try decodeSpec(
      #"{"items": [{"id": "i", "text": "t", "type": "integer"}, {"id": "n", "text": "t", "type": "number"}, {"id": "m", "text": "t", "type": "multi", "choices": ["a", "b"]}, {"id": "c", "text": "t", "type": "color"}, {"id": "f", "text": "t", "type": "file", "multiple": true}, {"id": "b", "text": "t", "type": "boolean"}]}"#
    )

    let value = FormAnswerValue.answers(
      spec: spec,
      answers: [
        "i": .number("12"), "n": .number("0.5"), "m": .list(["b", "a"]), "c": .text("#AABBCC"),
        "f": .list(["/a"]), "b": .boolean(false),
      ])

    XCTAssertEqual(
      value,
      .record([
        "i": .integer(12), "n": .number(0.5), "m": .array([.string("b"), .string("a")]),
        "c": .string("#aabbccff"), "f": .array([.string("/a")]), "b": .bool(false),
      ]))

    let unchecked = FormAnswerValue.answers(
      spec: spec, answers: ["i": .number("abc"), "m": .list([])])

    XCTAssertEqual(
      unchecked, .record(["i": .null, "n": .null, "m": .null, "c": .null, "f": .null, "b": .null]))
  }
}
