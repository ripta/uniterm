import ControllerPackage
import Foundation
import ScriptWire
import XCTest

@testable import QuestionForm

func decodeSpec(_ json: String) throws -> FormSpec {
  try FormSpecReader.decode(Data(json.utf8))
}

func refusal(_ json: String, file: StaticString = #filePath, line: UInt = #line) -> FormSpecError? {
  do {
    _ = try decodeSpec(json)
    XCTFail("the spec was accepted: \(json)", file: file, line: line)

    return nil
  } catch let error as FormSpecError {
    return error
  } catch {
    XCTFail("a non-spec error: \(error)", file: file, line: line)

    return nil
  }
}

func oneQuestion(_ body: String) -> String {
  #"{"items": [{"id": "q", "text": "Q?", \#(body)}]}"#
}

/// Proves the spec reader's contract: every answer type, content block, and button role reads,
/// and every unknown key, misapplied keyword, and cap refuses with the spec's own field name.
/// It cannot prove the widget side, which reads the model and the caps this file pins.
final class FormSpecTests: XCTestCase {
  func testTheSpecInTheProposalReads() throws {
    let spec = try decodeSpec(
      """
      {"title": "Deploy settings", "items": [
        {"block": "notice", "level": "warning", "text": "This deploys to production."},
        {"id": "region", "text": "Which region?", "type": "choice",
         "choices": ["us-east", "eu-west"], "other": true, "required": true},
        {"id": "replicas", "text": "How many replicas?", "type": "integer",
         "default": 3, "validate": {"minimum": 1, "maximum": 20}},
        {"id": "notes", "text": "Anything else?", "type": "text", "multiline": true,
         "validate": {"maxLength": 500}}],
       "actions": [
        {"id": "deploy", "label": "Deploy", "role": "primary"},
        {"id": "skip", "label": "Skip", "validates": false},
        {"id": "cancel", "role": "cancel"}]}
      """)

    XCTAssertEqual(spec.title, "Deploy settings")
    XCTAssertEqual(spec.items.count, 4)
    XCTAssertEqual(spec.questions.map(\.id), ["region", "replicas", "notes"])
    XCTAssertEqual(
      spec.buttons.map(\.role), [.primary, .normal, .cancel])
    XCTAssertEqual(spec.buttons.map(\.validates), [true, false, false])
    XCTAssertEqual(spec.buttons[2].label, "Cancel")
  }

  func testNoActionsGivesOKAndCancel() throws {
    let spec = try decodeSpec(oneQuestion(#""type": "boolean""#))

    XCTAssertEqual(spec.buttons, FormSpec.defaultButtons)
    XCTAssertEqual(spec.buttons.map(\.role), [.primary, .cancel])
  }

  func testEveryAnswerTypeReads() throws {
    let bodies: [(String, String)] = [
      (#""type": "boolean", "default": true"#, "boolean"),
      (#""type": "choice", "choices": ["a", "b"], "other": true, "default": "a""#, "choice"),
      (#""type": "multi", "choices": ["a", "b"], "default": ["b"]"#, "multi"),
      (#""type": "string", "default": "x", "placeholder": "p""#, "string"),
      (#""type": "text", "multiline": true"#, "text"),
      (#""type": "integer", "default": -4"#, "integer"),
      (#""type": "number", "default": 2.5"#, "number"),
      (##""type": "color", "default": "#1A2b3c""##, "color"),
      (#""type": "file", "mode": "save", "multiple": false, "types": ["public.json"]"#, "file"),
    ]

    for (body, name) in bodies {
      let spec = try decodeSpec(oneQuestion(body + #", "detail": "d", "required": true"#))

      XCTAssertEqual(spec.questions[0].type.name, name)
      XCTAssertEqual(spec.questions[0].detail, "d")
      XCTAssertTrue(spec.questions[0].isRequired)
    }

    let color = try decodeSpec(oneQuestion(##""type": "color", "default": "#1A2b3c""##))

    XCTAssertEqual(color.questions[0].type, .color(defaultValue: "#1a2b3cff"))
  }

  func testEveryContentBlockReads() throws {
    let spec = try decodeSpec(
      """
      {"items": [
        {"block": "paragraph", "text": "p"},
        {"block": "list", "items": ["a", "b"]},
        {"block": "code", "text": "ls -l"},
        {"block": "table", "rows": {"Region": "us-east", "Replicas": "3"}},
        {"block": "notice", "text": "n"},
        {"block": "notice", "level": "danger", "text": "n"}]}
      """)

    XCTAssertEqual(
      spec.items,
      [
        .block(.paragraph("p")), .block(.list(["a", "b"])), .block(.code("ls -l")),
        .block(
          .table([
            FormTableRow(key: "Region", value: "us-east"),
            FormTableRow(key: "Replicas", value: "3"),
          ])),
        .block(.notice(level: .info, text: "n")), .block(.notice(level: .danger, text: "n")),
      ])
    XCTAssertEqual(spec.questions, [])
  }

  func testEveryButtonRoleReads() throws {
    let spec = try decodeSpec(
      """
      {"items": [{"block": "paragraph", "text": "p"}], "actions": [
        {"id": "a", "role": "primary"}, {"id": "b", "role": "normal"},
        {"id": "c", "role": "destructive", "label": "Wipe"}, {"id": "d", "role": "cancel"}]}
      """)

    XCTAssertEqual(spec.buttons.map(\.role), [.primary, .normal, .destructive, .cancel])
    XCTAssertEqual(spec.buttons.map(\.validates), [true, true, true, false])
    XCTAssertEqual(spec.buttons.map(\.label), ["a", "b", "Wipe", "Cancel"])
  }

  /// Catches a reader that ignores a key it does not know, which would close a script's form
  /// while the script believed a later feature had run.
  func testEveryUnknownKeyRefusesAtItsLevel() {
    let cases: [(String, String)] = [
      (#"{"items": [{"block": "paragraph", "text": "p"}], "extra": 1}"#, "extra"),
      (#"{"items": [{"block": "paragraph", "text": "p", "x": 1}]}"#, "items[0].x"),
      (#"{"items": [{"block": "table", "rows": {"a": "b"}, "x": 1}]}"#, "items[0].x"),
      (oneQuestion(#""type": "boolean", "review": true"#), "items[0].review"),
      (
        oneQuestion(#""type": "string", "validate": {"minLength": 1, "format": "x"}"#),
        "items[0].validate.format"
      ),
      (
        #"{"items": [{"block": "paragraph", "text": "p"}], "actions": [{"id": "a", "icon": "x"}]}"#,
        "actions[0].icon"
      ),
    ]

    for (json, field) in cases {
      XCTAssertEqual(refusal(json)?.field, field, json)
    }
  }

  /// Catches a keyword or field applied to a type that cannot use it.
  func testMisappliedKeywordsRefuse() {
    let cases: [(String, String)] = [
      (#""type": "integer", "validate": {"minLength": 2}"#, "items[0].validate.minLength"),
      (#""type": "string", "validate": {"minimum": 2}"#, "items[0].validate.minimum"),
      (#""type": "string", "validate": {"minItems": 2}"#, "items[0].validate.minItems"),
      (#""type": "boolean", "validate": {}"#, "items[0].validate"),
      (#""type": "choice", "choices": ["a"], "validate": {}"#, "items[0].validate"),
      (#""type": "color", "validate": {"pattern": "a"}"#, "items[0].validate"),
      (
        #""type": "multi", "choices": ["a"], "validate": {"maxLength": 1}"#,
        "items[0].validate.maxLength"
      ),
      (#""type": "file", "validate": {"minItems": 1}"#, "items[0].validate.minItems"),
      (#""type": "integer", "multiline": true"#, "items[0].multiline"),
      (#""type": "boolean", "placeholder": "p""#, "items[0].placeholder"),
      (#""type": "multi", "choices": ["a"], "other": true"#, "items[0].other"),
      (#""type": "file", "default": "x""#, "items[0].default"),
    ]

    for (body, field) in cases {
      XCTAssertEqual(refusal(oneQuestion(body))?.field, field, body)
    }

    XCTAssertTrue(
      refusal(oneQuestion(#""type": "integer", "validate": {"minLength": 2}"#))!.reason
        .contains("does not apply to a integer question"))
  }

  func testBadValuesRefuseNamingTheField() {
    let cases: [(String, String)] = [
      (#"{"items": []}"#, "items"),
      (#"{}"#, "items"),
      (#"{"items": [3]}"#, "items[0]"),
      (#"{"items": [{"text": "a"}]}"#, "items[0]"),
      (#"{"items": [{"block": "paragraph", "type": "boolean", "text": "a"}]}"#, "items[0]"),
      (#"{"items": [{"block": "image", "text": "a"}]}"#, "items[0].block"),
      (oneQuestion(#""type": "slider""#), "items[0].type"),
      (oneQuestion(#""type": "boolean", "required": "yes""#), "items[0].required"),
      (oneQuestion(#""type": "choice", "choices": []"#), "items[0].choices"),
      (oneQuestion(#""type": "choice", "choices": ["a", "a"]"#), "items[0].choices"),
      (oneQuestion(#""type": "choice", "choices": ["a"], "default": "b""#), "items[0].default"),
      (
        oneQuestion(#""type": "multi", "choices": ["a"], "default": ["a", "a"]"#),
        "items[0].default"
      ),
      (oneQuestion(#""type": "integer", "default": 1.5"#), "items[0].default"),
      (
        oneQuestion(#""type": "integer", "default": 5, "validate": {"maximum": 4}"#),
        "items[0].default"
      ),
      (oneQuestion(#""type": "color", "default": "red""#), "items[0].default"),
      (
        oneQuestion(#""type": "string", "validate": {"minLength": 5, "maxLength": 2}"#),
        "items[0].validate.minLength"
      ),
      (
        oneQuestion(#""type": "string", "validate": {"maxLength": -1}"#),
        "items[0].validate.maxLength"
      ),
      (
        oneQuestion(#""type": "integer", "validate": {"minimum": 5, "maximum": 2}"#),
        "items[0].validate"
      ),
      (
        oneQuestion(#""type": "integer", "validate": {"multipleOf": 0}"#),
        "items[0].validate.multipleOf"
      ),
      (
        oneQuestion(#""type": "integer", "validate": {"minimum": "1"}"#),
        "items[0].validate.minimum"
      ),
      (
        oneQuestion(#""type": "integer", "validate": {"minimum": 1e99}"#),
        "items[0].validate.minimum"
      ),
      (
        oneQuestion(#""type": "file", "multiple": true, "validate": {"maxItems": 17}"#),
        "items[0].validate.maxItems"
      ),
      (oneQuestion(#""type": "file", "mode": "browse""#), "items[0].mode"),
      (
        #"{"items": [{"id": "a", "text": "t", "type": "boolean"}, {"id": "a", "text": "t", "type": "boolean"}]}"#,
        "items[1].id"
      ),
      (#"{"items": [{"id": "has space", "text": "t", "type": "boolean"}]}"#, "items[0].id"),
      (#"{"items": [{"id": "", "text": "t", "type": "boolean"}]}"#, "items[0].id"),
      (#"{"items": [{"id": "é", "text": "t", "type": "boolean"}]}"#, "items[0].id"),
      (#"{"items": [{"block": "notice", "level": "fatal", "text": "t"}]}"#, "items[0].level"),
      (#"{"items": [{"block": "list", "items": []}]}"#, "items[0].items"),
    ]

    for (json, field) in cases {
      let error = refusal(json.hasPrefix("{") ? json : json)

      XCTAssertEqual(error?.field, field, json)
      XCTAssertFalse(error?.description.contains("controller.json") ?? true)
    }
  }

  func testButtonRulesRefuse() {
    let items = #""items": [{"block": "paragraph", "text": "p"}]"#
    let cases: [(String, String)] = [
      (#"{\#(items), "actions": []}"#, "actions"),
      (
        #"{\#(items), "actions": [{"id": "a", "role": "primary"}, {"id": "b", "role": "primary"}]}"#,
        "actions[1].role"
      ),
      (
        #"{\#(items), "actions": [{"id": "a"}, {"id": "b", "role": "cancel"}, {"id": "c", "role": "cancel"}]}"#,
        "actions[2].role"
      ),
      (#"{\#(items), "actions": [{"id": "a", "role": "cancel"}]}"#, "actions"),
      (#"{\#(items), "actions": [{"id": "a"}, {"id": "a"}]}"#, "actions[1].id"),
      (#"{\#(items), "actions": [{"id": "a", "role": "default"}]}"#, "actions[0].role"),
      (
        #"{\#(items), "actions": [{"id": "a"}, {"id": "b", "role": "cancel", "validates": true}]}"#,
        "actions[1].validates"
      ),
      (#"{\#(items), "actions": [{"label": "x"}]}"#, "actions[0].id"),
      (#"{\#(items), "actions": [{"id": "a", "validates": "no"}]}"#, "actions[0].validates"),
    ]

    for (json, field) in cases {
      XCTAssertEqual(refusal(json)?.field, field, json)
    }
  }

  /// Catches a cap that is missing or off, one cap at a time. Each case is just over its limit.
  func testEachCapRefuses() {
    func long(_ count: Int) -> String { String(repeating: "x", count: count) }

    let items = #""items": [{"block": "paragraph", "text": "p"}]"#
    let tooManyItems = (0...FormLimits.maxItems).map { _ in #"{"block": "paragraph", "text": "p"}"#
    }
    let tooManyChoices = (0...FormLimits.maxChoices).map { "\"c\($0)\"" }.joined(separator: ",")
    let tooManyButtons = (0...FormLimits.maxButtons).map { #"{"id": "b\#($0)"}"# }.joined(
      separator: ",")
    let tooManyRows = (0...FormLimits.maxTableRows).map { "\"k\($0)\": \"v\"" }.joined(
      separator: ",")
    let tooManyEntries = (0...FormLimits.maxListEntries).map { _ in "\"e\"" }.joined(separator: ",")

    let cases: [(String, String)] = [
      (#"{"items": [\#(tooManyItems.joined(separator: ","))]}"#, "items"),
      (#"{"title": "\#(long(FormLimits.maxTitleBytes + 1))", \#(items)}"#, "title"),
      (
        #"{"items": [{"block": "paragraph", "text": "\#(long(FormLimits.maxBlockTextBytes + 1))"}]}"#,
        "items[0].text"
      ),
      (#"{"items": [{"block": "list", "items": [\#(tooManyEntries)]}]}"#, "items[0].items"),
      (
        #"{"items": [{"block": "list", "items": ["\#(long(FormLimits.maxListEntryBytes + 1))"]}]}"#,
        "items[0].items[0]"
      ),
      (#"{"items": [{"block": "table", "rows": {\#(tooManyRows)}}]}"#, "items[0].rows"),
      (
        #"{"items": [{"block": "table", "rows": {"\#(long(FormLimits.maxTableKeyBytes + 1))": "v"}}]}"#,
        "items[0].rows.\(long(FormLimits.maxTableKeyBytes + 1))"
      ),
      (#"{\#(items), "actions": [\#(tooManyButtons)]}"#, "actions"),
      (
        #"{\#(items), "actions": [{"id": "\#(long(FormLimits.maxIDBytes + 1))"}]}"#, "actions[0].id"
      ),
      (
        #"{\#(items), "actions": [{"id": "a", "label": "\#(long(FormLimits.maxLabelBytes + 1))"}]}"#,
        "actions[0].label"
      ),
      (oneQuestion(#""type": "choice", "choices": [\#(tooManyChoices)]"#), "items[0].choices"),
      (
        oneQuestion(#""type": "choice", "choices": ["\#(long(FormLimits.maxChoiceBytes + 1))"]"#),
        "items[0].choices[0]"
      ),
      (
        oneQuestion(
          #""type": "string", "default": "\#(long(FormLimits.maxStringAnswerBytes + 1))""#),
        "items[0].default"
      ),
      (
        oneQuestion(
          #""type": "string", "validate": {"maxLength": \#(FormLimits.maxStringAnswerBytes + 1)}"#),
        "items[0].validate.maxLength"
      ),
      (
        oneQuestion(
          #""type": "text", "validate": {"maxLength": \#(FormLimits.maxTextAnswerBytes + 1)}"#),
        "items[0].validate.maxLength"
      ),
      (
        oneQuestion(
          #""type": "string", "validate": {"pattern": "\#(long(FormLimits.maxPatternBytes + 1))"}"#),
        "items[0].validate.pattern"
      ),
      (
        oneQuestion(
          #""type": "string", "placeholder": "\#(long(FormLimits.maxPlaceholderBytes + 1))""#),
        "items[0].placeholder"
      ),
      (
        oneQuestion(
          #""type": "file", "types": [\#((0...FormLimits.maxFileTypes).map { "\"t\($0)\"" }.joined(separator: ","))]"#
        ), "items[0].types"
      ),
      (oneQuestion(#""type": "integer", "default": 123456789012345678901"#), "items[0].default"),
      (oneQuestion(#""type": "integer", "default": 1e21"#), "items[0].default"),
    ]

    for (json, field) in cases {
      XCTAssertEqual(refusal(json)?.field, field, String(json.prefix(120)))
    }
  }

  func testTheSpecIsCappedInBytesAndDepthAndStrictness() {
    let big =
      #"{"items": [{"block": "paragraph", "text": "\#(String(repeating: "x", count: FormLimits.maxSpecBytes))"}]}"#

    XCTAssertEqual(refusal(big)?.field, "spec")
    XCTAssertEqual(
      refusal(#"{"items": [{"block": "paragraph", "text": "a", "text": "b"}]}"#)?.field, "spec")
    XCTAssertEqual(refusal(#"{"items": [[[[[[[[[1]]]]]]]]]}"#)?.field, "spec")
    XCTAssertEqual(refusal(#"[]"#)?.field, "spec")
    XCTAssertEqual(
      refusal("{\"items\": [{\"block\": \"paragraph\", \"text\": \"a\\u0000\"}]}")?.field, "spec")
  }

  /// Catches a spec whose answers could not fit one reply. A cut answer would reach the script as
  /// if it were whole.
  func testTheWorstCaseResultMustFitOneReply() throws {
    func strings(_ count: Int) -> String {
      let items = (0..<count).map { #"{"id": "q\#($0)", "text": "t", "type": "text"}"# }

      return #"{"items": [\#(items.joined(separator: ","))]}"#
    }

    var fitting = 0

    while (try? decodeSpec(strings(fitting + 1))) != nil { fitting += 1 }

    XCTAssertGreaterThanOrEqual(fitting, 14)
    XCTAssertEqual(refusal(strings(fitting + 1))?.field, "items[\(fitting)]")

    let spec = try decodeSpec(strings(fitting))
    let full = String(repeating: "é", count: FormLimits.maxTextAnswerBytes / 2)
    let answers = Dictionary(
      uniqueKeysWithValues: spec.questions.map { ($0.id, FormAnswer.text(full)) })
    let result = FormOutcome.submitted(
      submission: Int(ScriptProtocol.maxID), action: "x", answers: answers
    )
    .scriptValue(form: ScriptProtocol.maxID, spec: spec)!
    let bytes = try result.encoded()

    XCTAssertLessThanOrEqual(bytes.count, ScriptProtocol.maxReplyPayload)
    XCTAssertGreaterThan(bytes.count, spec.questions.count * FormLimits.maxTextAnswerBytes)

    guard case .record(let top) = result, case .record(let fields)? = top["answers"] else {
      return XCTFail("no answers record")
    }

    for value in fields.values { XCTAssertEqual(value, .string(full)) }
  }

  /// The answers record is a reply record, so the spec's question count meets the encoder's field
  /// cap and every id is a legal key.
  func testAFormOfEveryQuestionTheCapAllowsFitsOneReply() throws {
    let items = (0..<FormLimits.maxItems).map {
      #"{"id": "q\#($0)", "text": "t", "type": "integer"}"#
    }
    let spec = try decodeSpec(#"{"items": [\#(items.joined(separator: ","))]}"#)
    let answers = Dictionary(
      uniqueKeysWithValues: spec.questions.map { ($0.id, FormAnswer.number("-9007199254740991")) })
    let bytes = try FormOutcome.submitted(submission: 1, action: "ok", answers: answers)
      .scriptValue(form: 1, spec: spec)!.encoded()

    XCTAssertLessThanOrEqual(bytes.count, ScriptProtocol.maxReplyPayload)
  }

  func testResultShapes() throws {
    let spec = try decodeSpec(
      #"{"items": [{"id": "a", "text": "t", "type": "integer"}, {"id": "b", "text": "t", "type": "string"}, {"id": "c", "text": "t", "type": "boolean"}]}"#
    )

    XCTAssertEqual(
      FormOutcome.submitted(
        submission: 1, action: "ok", answers: ["a": .number("-3"), "b": .text("hi")]
      ).scriptValue(form: 7, spec: spec),
      .record([
        "form": .integer(7), "submission": .integer(1), "action": .string("ok"),
        "answers": .record(["a": .number(-3), "b": .string("hi"), "c": .null]),
      ]))
    XCTAssertEqual(
      FormOutcome.cancelled(action: "cancel").scriptValue(form: 7, spec: spec),
      .record(["form": .integer(7), "outcome": .string("cancelled"), "action": .string("cancel")]))
    XCTAssertEqual(
      FormOutcome.dismissed.scriptValue(form: 7, spec: spec),
      .record(["form": .integer(7), "outcome": .string("dismissed")]))
    XCTAssertNil(FormOutcome.ended.scriptValue(form: 7, spec: spec))
  }

  /// Catches a result that leans on the widgets for its caps. A button that does not validate
  /// submits whatever is filled in, and the reply encoder would cut an overlong string silently.
  func testEveryCapHoldsInTheResultWhateverIsSubmitted() throws {
    let spec = try decodeSpec(
      """
      {"items": [
        {"id": "s", "text": "t", "type": "string"},
        {"id": "t", "text": "t", "type": "text", "validate": {"maxLength": 10}},
        {"id": "c", "text": "t", "type": "color"},
        {"id": "m", "text": "t", "type": "multi", "choices": ["a", "b", "c"],
         "validate": {"maxItems": 2}},
        {"id": "f", "text": "t", "type": "file", "multiple": true, "validate": {"maxItems": 2}},
        {"id": "p", "text": "t", "type": "file"},
        {"id": "i", "text": "t", "type": "integer"},
        {"id": "o", "text": "t", "type": "choice", "choices": ["a"], "other": true}]}
      """)

    let long = String(repeating: "é", count: 5000)
    let result = FormOutcome.submitted(
      submission: -5, action: String(repeating: "x", count: 100),
      answers: [
        "s": .text(long), "t": .text(long), "c": .text("#12345"), "o": .text(long),
        "m": .list(["a", "b", "c"]), "f": .list([long, "/b", "/c"]), "p": .list([long, "/b"]),
        "i": .number("1.5"),
      ]
    ).scriptValue(form: 1, spec: spec)!

    guard case .record(let top) = result, case .record(let answers)? = top["answers"] else {
      return XCTFail("no answers record")
    }

    func size(_ value: ScriptValue?) -> Int {
      guard case .string(let text)? = value else { return -1 }

      return text.utf8.count
    }

    XCTAssertEqual(top["submission"], .integer(0))
    XCTAssertEqual(size(top["action"]), FormLimits.maxIDBytes)
    XCTAssertEqual(size(answers["s"]), FormLimits.maxStringAnswerBytes)
    XCTAssertEqual(size(answers["t"]), 40)
    XCTAssertEqual(size(answers["o"]), FormLimits.maxOtherBytes)
    XCTAssertEqual(answers["c"], .null)
    XCTAssertEqual(answers["i"], .null)
    XCTAssertEqual(answers["m"], .array([.string("a"), .string("b")]))

    guard case .array(let paths)? = answers["f"] else { return XCTFail("no paths") }

    XCTAssertEqual(paths.count, 2)
    XCTAssertEqual(size(paths[0]), FormLimits.maxPathBytes)
    XCTAssertEqual(size(answers["p"]), FormLimits.maxPathBytes)

    XCTAssertEqual(
      FormAnswerValue.value(spec.questions[2], .text("#ABCDEF")), .string("#abcdefff"))
    XCTAssertLessThanOrEqual(try result.encoded().count, FormLimits.maxResultBytes)
  }
}
