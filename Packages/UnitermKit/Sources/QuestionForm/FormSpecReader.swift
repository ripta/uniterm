import ControllerPackage
import Foundation
import ScriptWire

/// Reads a form spec through the strict JSON reader. Any unknown key, at any level, refuses the
/// spec, so a script written for a later uniterm fails loudly on this one. Every error names the
/// spec's own field.
public enum FormSpecReader {
  public static func decode(_ bytes: Data) throws -> FormSpec {
    let json: StrictJSON

    do {
      json = try StrictJSONReader.parse(bytes, maxBytes: FormLimits.maxSpecBytes)
    } catch let error as StrictJSONError {
      throw FormSpecError(field: "spec", reason: error.description)
    }

    return try decode(json)
  }

  public static func decode(_ json: StrictJSON) throws -> FormSpec {
    let object = try Fields(json, path: "", required: ["items"], optional: ["title", "actions"])

    let title = try object["title"].map {
      try text($0, object.path("title"), FormLimits.maxTitleBytes)
    }
    let items = try readItems(object["items"]!)
    let buttons = try object["actions"].map { try readButtons($0) } ?? FormSpec.defaultButtons

    guard buttons.contains(where: { $0.role != .cancel }) else {
      throw FormSpecError(field: "actions", reason: "needs a button that is not a cancel button")
    }

    let spec = FormSpec(title: title, items: items, buttons: buttons)

    try checkResultBudget(spec)

    return spec
  }

  // MARK: Items

  private static func readItems(_ json: StrictJSON) throws -> [FormItem] {
    guard case .array(let elements) = json else {
      throw FormSpecError(field: "items", reason: "must be an array")
    }

    guard !elements.isEmpty else {
      throw FormSpecError(field: "items", reason: "needs at least one item")
    }

    guard elements.count <= FormLimits.maxItems else {
      throw FormSpecError(
        field: "items",
        reason: "holds \(elements.count) items, over the limit of \(FormLimits.maxItems)")
    }

    var seen = Set<String>()
    var items: [FormItem] = []

    for (offset, element) in elements.enumerated() {
      let path = "items[\(offset)]"

      guard case .object(let members) = element else {
        throw FormSpecError(field: path, reason: "must be an object")
      }

      let keys = Set(members.map(\.key))

      switch (keys.contains("block"), keys.contains("type")) {
      case (true, true):
        throw FormSpecError(field: path, reason: "is a block or a question, not both")

      case (true, false):
        items.append(.block(try block(element, path: path)))

      case (false, true):
        let question = try question(element, path: path)

        guard seen.insert(question.id).inserted else {
          throw FormSpecError(field: "\(path).id", reason: "repeats the id \"\(question.id)\"")
        }

        items.append(.question(question))

      case (false, false):
        throw FormSpecError(field: path, reason: "needs a \"type\" for a question or a \"block\"")
      }
    }

    return items
  }

  // MARK: Blocks

  private static func block(_ json: StrictJSON, path: String) throws -> FormBlock {
    guard case .object(let members) = json,
      case .string(let kind)? = members.first(where: { $0.key == "block" })?.value
    else { throw FormSpecError(field: "\(path).block", reason: "must be a string") }

    switch kind {
    case "paragraph", "code":
      let fields = try Fields(json, path: path, required: ["block", "text"])
      let body = try text(fields["text"]!, fields.path("text"), FormLimits.maxBlockTextBytes)

      return kind == "code" ? .code(body) : .paragraph(body)

    case "list":
      let fields = try Fields(json, path: path, required: ["block", "items"])
      let entries = try array(
        fields["items"]!, fields.path("items"), max: FormLimits.maxListEntries)

      guard !entries.isEmpty else {
        throw FormSpecError(field: fields.path("items"), reason: "needs at least one entry")
      }

      return .list(
        try entries.enumerated().map {
          try text(
            $0.element, "\(fields.path("items"))[\($0.offset)]", FormLimits.maxListEntryBytes)
        })

    case "table":
      let fields = try Fields(json, path: path, required: ["block", "rows"])
      let rows = try object(fields["rows"]!, fields.path("rows"), max: FormLimits.maxTableRows)

      return .table(
        try rows.map {
          let at = "\(fields.path("rows")).\($0.key)"

          guard !$0.key.isEmpty, $0.key.utf8.count <= FormLimits.maxTableKeyBytes else {
            throw FormSpecError(
              field: at, reason: "is a row name over \(FormLimits.maxTableKeyBytes) bytes or empty")
          }

          return FormTableRow(
            key: $0.key,
            value: try text($0.value, at, FormLimits.maxTableValueBytes, allowEmpty: true)
          )
        })

    case "notice":
      let fields = try Fields(json, path: path, required: ["block", "text"], optional: ["level"])
      let level = try fields["level"].map {
        try closedSet($0, fields.path("level"), FormNoticeLevel.self)
      }

      return .notice(
        level: level ?? .info,
        text: try text(fields["text"]!, fields.path("text"), FormLimits.maxBlockTextBytes))

    default:
      throw FormSpecError(
        field: "\(path).block",
        reason: "is \"\(kind)\", and must be paragraph, list, code, table, or notice")
    }
  }

  // MARK: Questions

  private static let questionKeys: [String: Set<String>] = [
    "boolean": ["default"],
    "choice": ["default", "choices", "other"],
    "multi": ["default", "choices", "validate"],
    "string": ["default", "placeholder", "validate"],
    "text": ["default", "placeholder", "validate", "multiline"],
    "integer": ["default", "placeholder", "validate"],
    "number": ["default", "placeholder", "validate"],
    "color": ["default"],
    "file": ["validate", "mode", "multiple", "types"],
  ]

  private static let allQuestionKeys = Set(questionKeys.values.flatMap { $0 })

  private static func question(_ json: StrictJSON, path: String) throws -> FormQuestion {
    guard case .object(let members) = json,
      case .string(let kind)? = members.first(where: { $0.key == "type" })?.value
    else { throw FormSpecError(field: "\(path).type", reason: "must be a string") }

    guard let typeKeys = questionKeys[kind] else {
      throw FormSpecError(
        field: "\(path).type",
        reason:
          "is \"\(kind)\", and must be one of \(questionKeys.keys.sorted().joined(separator: ", "))"
      )
    }

    var hints: [String: String] = [:]

    for key in allQuestionKeys where !typeKeys.contains(key) {
      hints[key] = "does not apply to a \(kind) question"
    }

    let fields = try Fields(
      json, path: path, required: ["id", "text", "type"],
      optional: typeKeys.union(["detail", "required"]), hints: hints)

    let id = try identifier(fields["id"]!, fields.path("id"))
    let questionText = try text(
      fields["text"]!, fields.path("text"), FormLimits.maxQuestionTextBytes)
    let detail = try fields["detail"].map {
      try text($0, fields.path("detail"), FormLimits.maxDetailBytes)
    }
    let isRequired = try fields["required"].map { try bool($0, fields.path("required")) } ?? false
    let placeholder = try fields["placeholder"].map {
      try text($0, fields.path("placeholder"), FormLimits.maxPlaceholderBytes)
    }

    let type = try questionType(kind, fields: fields)

    var validation = FormValidation()

    if let validate = fields["validate"] {
      validation = try self.validation(
        validate, kind: kind, type: type, path: fields.path("validate"))
    }

    let question = FormQuestion(
      id: id, text: questionText, detail: detail, isRequired: isRequired, placeholder: placeholder,
      type: type, validation: validation)

    try checkDefault(question, path: fields.path("default"))

    return question
  }

  private static func questionType(_ kind: String, fields: Fields) throws -> FormQuestionType {
    let path = fields.path("default")

    switch kind {
    case "boolean":
      return .boolean(defaultValue: try fields["default"].map { try bool($0, path) })

    case "choice":
      let choices = try choices(fields["choices"], fields.path("choices"))

      return .choice(
        choices: choices,
        allowsOther: try fields["other"].map { try bool($0, fields.path("other")) } ?? false,
        defaultValue: try fields["default"].map {
          try text($0, path, FormLimits.maxOtherBytes)
        })

    case "multi":
      let choices = try choices(fields["choices"], fields.path("choices"))

      return .multi(
        choices: choices,
        defaultValue: try fields["default"].map {
          try array($0, path, max: FormLimits.maxChoices).enumerated().map {
            try text($0.element, "\(path)[\($0.offset)]", FormLimits.maxChoiceBytes)
          }
        })

    case "string":
      return .string(
        defaultValue: try fields["default"].map {
          try text($0, path, FormLimits.maxStringAnswerBytes, allowEmpty: true)
        })

    case "text":
      return .text(
        multiline: try fields["multiline"].map { try bool($0, fields.path("multiline")) } ?? false,
        defaultValue: try fields["default"].map {
          try text($0, path, FormLimits.maxTextAnswerBytes, allowEmpty: true)
        })

    case "integer":
      return .integer(defaultValue: try fields["default"].map { try decimal($0, path) })

    case "number":
      return .number(defaultValue: try fields["default"].map { try decimal($0, path) })

    case "color":
      return .color(
        defaultValue: try fields["default"].map {
          let value = try text($0, path, 9)

          guard let color = FormChecker.normalizedColor(value) else {
            throw FormSpecError(field: path, reason: "must be #rrggbb or #rrggbbaa")
          }

          return color
        })

    default:
      let types = try fields["types"].map {
        try array($0, fields.path("types"), max: FormLimits.maxFileTypes).enumerated().map {
          try text($0.element, "\(fields.path("types"))[\($0.offset)]", FormLimits.maxFileTypeBytes)
        }
      }

      return .file(
        mode: try fields["mode"].map { try closedSet($0, fields.path("mode"), FormFileMode.self) }
          ?? .open,
        multiple: try fields["multiple"].map { try bool($0, fields.path("multiple")) } ?? false,
        types: types ?? [])
    }
  }

  private static func choices(_ json: StrictJSON?, _ path: String) throws -> [String] {
    let entries = try array(json!, path, max: FormLimits.maxChoices)

    guard !entries.isEmpty else {
      throw FormSpecError(field: path, reason: "needs at least one choice")
    }

    let choices = try entries.enumerated().map {
      try text($0.element, "\(path)[\($0.offset)]", FormLimits.maxChoiceBytes)
    }

    if let repeated = Dictionary(grouping: choices, by: { $0 }).first(where: { $1.count > 1 }) {
      throw FormSpecError(field: path, reason: "repeats the choice \"\(repeated.key)\"")
    }

    return choices
  }

  private static func checkDefault(_ question: FormQuestion, path: String) throws {
    let answer: FormAnswer

    switch question.type {
    case .boolean(let value?): answer = .boolean(value)
    case .choice(_, _, let value?): answer = .text(value)
    case .multi(_, let value?): answer = .list(value)
    case .string(let value?), .text(_, let value?), .color(let value?): answer = .text(value)
    case .integer(let value?), .number(let value?): answer = .number(value.literal)
    default: return
    }

    switch FormChecker.verdict(question, answer) {
    case .invalid(let message):
      throw FormSpecError(field: path, reason: "fails its own rules: \(message)")
    case .valid, .needsPattern: return
    }
  }

  // MARK: Validation keywords

  private static let validationKeys: [String: Set<String>] = [
    "string": ["minLength", "maxLength", "pattern"],
    "text": ["minLength", "maxLength", "pattern"],
    "integer": ["minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf"],
    "number": ["minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf"],
    "multi": ["minItems", "maxItems"],
    "file": ["minItems", "maxItems"],
  ]

  private static let allValidationKeys = Set(validationKeys.values.flatMap { $0 })

  private static func validation(
    _ json: StrictJSON, kind: String, type: FormQuestionType, path: String
  ) throws -> FormValidation {
    var allowed = validationKeys[kind] ?? []

    if case .file(_, let multiple, _) = type, !multiple { allowed = [] }

    var hints: [String: String] = [:]

    for key in allValidationKeys where !allowed.contains(key) {
      hints[key] = "does not apply to a \(kind) question"
    }

    let fields = try Fields(json, path: path, required: [], optional: allowed, hints: hints)

    var result = FormValidation()
    let characterLimit =
      kind == "string" ? FormLimits.maxStringAnswerBytes : FormLimits.maxTextAnswerBytes

    result.minLength = try fields["minLength"].map {
      try count($0, fields.path("minLength"), max: characterLimit)
    }

    result.maxLength = try fields["maxLength"].map {
      try count($0, fields.path("maxLength"), max: characterLimit)
    }

    if let minimum = result.minLength, let maximum = result.maxLength, minimum > maximum {
      throw FormSpecError(field: fields.path("minLength"), reason: "is above maxLength")
    }

    if let pattern = fields["pattern"] {
      let at = fields.path("pattern")
      let source = try text(pattern, at, FormLimits.maxPatternBytes)

      do {
        result.pattern = try PatternProgram(source: source)
      } catch let error as PatternError {
        throw FormSpecError(field: at, reason: "holds \(error.reason)")
      }
    }

    result.minimum = try fields["minimum"].map { try decimal($0, fields.path("minimum")) }
    result.maximum = try fields["maximum"].map { try decimal($0, fields.path("maximum")) }
    result.exclusiveMinimum = try fields["exclusiveMinimum"].map {
      try decimal($0, fields.path("exclusiveMinimum"))
    }
    result.exclusiveMaximum = try fields["exclusiveMaximum"].map {
      try decimal($0, fields.path("exclusiveMaximum"))
    }

    if let lower = result.minimum ?? result.exclusiveMinimum,
      let upper = result.maximum ?? result.exclusiveMaximum, lower > upper
    {
      throw FormSpecError(field: path, reason: "has a lower bound above its upper bound")
    }

    result.multipleOf = try fields["multipleOf"].map {
      let step = try decimal($0, fields.path("multipleOf"))

      guard step.value > 0 else {
        throw FormSpecError(field: fields.path("multipleOf"), reason: "must be above zero")
      }

      return step
    }

    let entryCap = kind == "file" ? FormLimits.maxFilePaths : FormLimits.maxChoices

    result.minItems = try fields["minItems"].map {
      try count($0, fields.path("minItems"), max: entryCap)
    }
    result.maxItems = try fields["maxItems"].map {
      try count($0, fields.path("maxItems"), max: entryCap)
    }

    if let minimum = result.minItems, let maximum = result.maxItems, minimum > maximum {
      throw FormSpecError(field: fields.path("minItems"), reason: "is above maxItems")
    }

    return result
  }

  // MARK: Buttons

  private static func readButtons(_ json: StrictJSON) throws -> [FormButton] {
    let elements = try array(json, "actions", max: FormLimits.maxButtons)

    guard !elements.isEmpty else {
      throw FormSpecError(field: "actions", reason: "needs at least one button")
    }

    var ids = Set<String>()
    var buttons: [FormButton] = []

    for (offset, element) in elements.enumerated() {
      let fields = try Fields(
        element, path: "actions[\(offset)]", required: ["id"],
        optional: ["label", "role", "validates"])

      let id = try identifier(fields["id"]!, fields.path("id"))

      guard ids.insert(id).inserted else {
        throw FormSpecError(field: fields.path("id"), reason: "repeats the id \"\(id)\"")
      }

      let role =
        try fields["role"].map { try closedSet($0, fields.path("role"), FormButtonRole.self) }
        ?? .normal

      let label =
        try fields["label"].map { try text($0, fields.path("label"), FormLimits.maxLabelBytes) }
        ?? (role == .cancel ? "Cancel" : id)

      var validates = role != .cancel

      if let value = fields["validates"] {
        validates = try bool(value, fields.path("validates"))

        if role == .cancel, validates {
          throw FormSpecError(
            field: fields.path("validates"), reason: "cannot be true on a cancel button")
        }
      }

      buttons.append(FormButton(id: id, label: label, role: role, validates: validates))
    }

    for role in [FormButtonRole.primary, .cancel] {
      let extra = buttons.enumerated().filter { $0.element.role == role }.dropFirst()

      if let extra = extra.first {
        throw FormSpecError(
          field: "actions[\(extra.offset)].role", reason: "is a second \(role.rawValue) button")
      }
    }

    return buttons
  }

  // MARK: Result budget

  /// Refuses a spec whose answers, all at their caps, would not fit one reply. The check builds
  /// the worst-case value of each answer and measures what the reply encoder writes, so the budget
  /// is the encoder's own.
  private static func checkResultBudget(_ spec: FormSpec) throws {
    let longestID = String(repeating: "x", count: FormLimits.maxIDBytes)
    let envelope = ScriptValue.record([
      "form": .integer(ScriptProtocol.maxID), "submission": .integer(ScriptProtocol.maxID),
      "action": .string(longestID), "answers": .record([:]),
    ])

    var total = try envelope.encoded().count

    for (offset, item) in spec.items.enumerated() {
      guard case .question(let question) = item else { continue }

      let value = worstCase(question)

      total += 1 + question.id.utf8.count + (try value.encoded().count)

      if total > FormLimits.maxResultBytes {
        throw FormSpecError(
          field: "items[\(offset)]",
          reason:
            "makes the answers too large for one reply, at \(total) bytes of \(FormLimits.maxResultBytes)"
        )
      }
    }
  }

  /// The largest value a question's answer can encode to.
  static func worstCase(_ question: FormQuestion) -> ScriptValue {
    func filler(_ bytes: Int) -> ScriptValue { .string(String(repeating: "x", count: bytes)) }

    switch question.type {
    case .boolean:
      return .bool(true)

    case .integer, .number:
      return .number(-1.5)

    case .string, .text, .color, .choice:
      return filler(question.answerByteLimit)

    case .multi(let choices, _):
      let sizes = choices.map { $0.utf8.count }.sorted(by: >).prefix(question.answerEntryLimit)

      return .array(sizes.map(filler))

    case .file:
      return question.answerEntryLimit > 1
        ? .array(
          Array(repeating: filler(FormLimits.maxPathBytes), count: question.answerEntryLimit))
        : filler(FormLimits.maxPathBytes)
    }
  }

  // MARK: Values

  private static func identifier(_ json: StrictJSON, _ path: String) throws -> String {
    let value = try text(json, path, FormLimits.maxIDBytes)

    guard value.utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7F }) else {
      throw FormSpecError(field: path, reason: "may hold only visible ASCII characters")
    }

    return value
  }

  private static func text(
    _ json: StrictJSON, _ path: String, _ limit: Int, allowEmpty: Bool = false
  ) throws -> String {
    guard case .string(let value) = json else {
      throw FormSpecError(field: path, reason: "must be a string")
    }

    guard allowEmpty || !value.isEmpty else {
      throw FormSpecError(field: path, reason: "must not be empty")
    }

    guard value.utf8.count <= limit else {
      throw FormSpecError(
        field: path, reason: "is \(value.utf8.count) bytes, over the limit of \(limit)")
    }

    return value
  }

  private static func bool(_ json: StrictJSON, _ path: String) throws -> Bool {
    guard case .boolean(let value) = json else {
      throw FormSpecError(field: path, reason: "must be true or false")
    }

    return value
  }

  private static func count(_ json: StrictJSON, _ path: String, max: Int) throws -> Int {
    guard case .integer(let value) = json else {
      throw FormSpecError(field: path, reason: "must be a whole number from 0")
    }

    guard value <= max else {
      throw FormSpecError(field: path, reason: "is \(value), over the limit of \(max)")
    }

    return value
  }

  private static func decimal(_ json: StrictJSON, _ path: String) throws -> ExactDecimal {
    let literal: String

    switch json {
    case .integer(let value): literal = String(value)
    case .number(let text): literal = text
    default: throw FormSpecError(field: path, reason: "must be a number")
    }

    guard let value = ExactDecimal(literal: literal) else {
      throw FormSpecError(
        field: path,
        reason:
          "must have at most \(FormLimits.maxNumberDigits) digits and an exponent within \(FormLimits.maxNumberExponent)"
      )
    }

    return value
  }

  private static func array(_ json: StrictJSON, _ path: String, max: Int) throws -> [StrictJSON] {
    guard case .array(let elements) = json else {
      throw FormSpecError(field: path, reason: "must be an array")
    }

    guard elements.count <= max else {
      throw FormSpecError(
        field: path, reason: "holds \(elements.count) entries, over the limit of \(max)")
    }

    return elements
  }

  private static func object(
    _ json: StrictJSON, _ path: String, max: Int
  ) throws -> [(key: String, value: StrictJSON)] {
    guard case .object(let members) = json else {
      throw FormSpecError(field: path, reason: "must be an object")
    }

    guard !members.isEmpty, members.count <= max else {
      throw FormSpecError(field: path, reason: "needs from 1 to \(max) rows")
    }

    return members
  }

  private static func closedSet<Value: RawRepresentable & CaseIterable>(
    _ json: StrictJSON, _ path: String, _: Value.Type
  ) throws -> Value where Value.RawValue == String {
    guard case .string(let name) = json else {
      throw FormSpecError(field: path, reason: "must be a string")
    }

    guard let value = Value(rawValue: name) else {
      let names = Value.allCases.map(\.rawValue).joined(separator: ", ")

      throw FormSpecError(field: path, reason: "is \"\(name)\", and must be one of \(names)")
    }

    return value
  }
}

/// The members of one object, checked against the fields its kind takes.
private struct Fields {
  let base: String
  let members: [String: StrictJSON]

  init(
    _ json: StrictJSON, path: String, required: Set<String>, optional: Set<String> = [],
    hints: [String: String] = [:]
  ) throws {
    guard case .object(let list) = json else {
      throw FormSpecError(field: path.isEmpty ? "spec" : path, reason: "must be an object")
    }

    base = path

    var found: [String: StrictJSON] = [:]

    for member in list {
      let at = path.isEmpty ? member.key : "\(path).\(member.key)"

      guard required.contains(member.key) || optional.contains(member.key) else {
        throw FormSpecError(field: at, reason: hints[member.key] ?? "is not a field of this object")
      }

      found[member.key] = member.value
    }

    for key in required.sorted() where found[key] == nil {
      throw FormSpecError(field: path.isEmpty ? key : "\(path).\(key)", reason: "is missing")
    }

    members = found
  }

  subscript(key: String) -> StrictJSON? { members[key] }

  func path(_ key: String) -> String { base.isEmpty ? key : "\(base).\(key)" }
}
