import Foundation

/// The JSON a `uniterm ask` shorthand sends as its form. Each shorthand is one question whose
/// answer is under the id `answer`, so the command reads it back the same way for every kind.
///
/// The text is built here, with the app's strict reader on the other end. A shorthand's flags are
/// checked for shape, and the app checks their meaning.
indirect enum ScriptAskSpec {
  case raw(String)
  case string(String)
  case bool(Bool)
  case array([ScriptAskSpec])
  case object([(String, ScriptAskSpec)])

  /// The id of the one question a shorthand asks.
  static let answerID = "answer"

  /// The id of the button that means Yes in a `confirm`.
  static let yesID = "yes"

  var text: String {
    switch self {
    case .raw(let literal): return literal
    case .string(let value): return ScriptAskOutput.quoted(value)
    case .bool(let flag): return flag ? "true" : "false"
    case .array(let items): return "[" + items.map(\.text).joined(separator: ",") + "]"

    case .object(let members):
      return "{"
        + members.map { ScriptAskOutput.quoted($0.0) + ":" + $0.1.text }.joined(separator: ",")
        + "}"
    }
  }

  /// Whether `literal` is a JSON number, so a flag's value cannot carry anything else into the
  /// spec.
  static func isJSONNumber(_ literal: String) -> Bool {
    let bytes = Array(literal.utf8)
    var index = 0

    func digits() -> Int {
      var count = 0

      while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 {
        index += 1
        count += 1
      }

      return count
    }

    if index < bytes.count, bytes[index] == 0x2D { index += 1 }

    guard index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 else { return false }

    if bytes[index] == 0x30 {
      index += 1
    } else {
      _ = digits()
    }

    if index < bytes.count, bytes[index] == 0x2E {
      index += 1

      guard digits() > 0 else { return false }
    }

    if index < bytes.count, bytes[index] == 0x65 || bytes[index] == 0x45 {
      index += 1

      if index < bytes.count, bytes[index] == 0x2B || bytes[index] == 0x2D { index += 1 }

      guard digits() > 0 else { return false }
    }

    return index == bytes.count
  }

  private static func question(
    _ prompt: String, type: String, extra: [(String, ScriptAskSpec)] = []
  ) -> ScriptAskSpec {
    .object([
      (
        "items",
        .array([
          .object(
            [
              ("id", .string(answerID)), ("text", .string(prompt)), ("type", .string(type)),
              ("required", .bool(true)),
            ] + extra)
        ])
      )
    ])
  }

  static func confirm(_ prompt: String) -> ScriptAskSpec {
    .object([
      ("items", .array([.object([("block", .string("paragraph")), ("text", .string(prompt))])])),
      (
        "actions",
        .array([
          .object([
            ("id", .string(yesID)), ("label", .string("Yes")), ("role", .string("primary")),
          ]),
          .object([("id", .string("no")), ("label", .string("No")), ("role", .string("cancel"))]),
        ])
      ),
    ])
  }

  static func text(_ prompt: String, default value: String?, pattern: String?) -> ScriptAskSpec {
    var extra: [(String, ScriptAskSpec)] = []

    if let value { extra.append(("default", .string(value))) }

    if let pattern { extra.append(("validate", .object([("pattern", .string(pattern))]))) }

    return question(prompt, type: "string", extra: extra)
  }

  static func choose(
    _ prompt: String, choices: [String], multiple: Bool, other: Bool
  ) -> ScriptAskSpec {
    var extra: [(String, ScriptAskSpec)] = [("choices", .array(choices.map { .string($0) }))]

    if other { extra.append(("other", .bool(true))) }

    return question(prompt, type: multiple ? "multi" : "choice", extra: extra)
  }

  static func number(
    _ prompt: String, integer: Bool, minimum: String?, maximum: String?
  ) -> ScriptAskSpec {
    var limits: [(String, ScriptAskSpec)] = []

    if let minimum { limits.append(("minimum", .raw(minimum))) }

    if let maximum { limits.append(("maximum", .raw(maximum))) }

    return question(
      prompt, type: integer ? "integer" : "number",
      extra: limits.isEmpty ? [] : [("validate", .object(limits))])
  }

  static func color(_ prompt: String) -> ScriptAskSpec {
    question(prompt, type: "color")
  }

  static func file(_ prompt: String, mode: String, types: [String]) -> ScriptAskSpec {
    var extra: [(String, ScriptAskSpec)] = []

    if mode != "open" { extra.append(("mode", .string(mode))) }

    if !types.isEmpty { extra.append(("types", .array(types.map { .string($0) }))) }

    return question(prompt, type: "file", extra: extra)
  }
}
