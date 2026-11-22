import Foundation
import ScriptWire

/// What `uniterm ask` writes to standard output, and how it reads a form's result.
enum ScriptAskOutput {
  /// How the user finished a form.
  enum Result: Equatable {
    /// A button other than the cancel button submitted the form.
    case answered(action: String, answers: [String: ScriptValue])

    /// The cancel button was pressed. It is not a submission.
    case cancelled

    /// The form's tab or pane closed.
    case dismissed
  }

  struct Unreadable: Error {
    let text: String
  }

  /// Reads the record a `wait-form` returns: `{form, submission, action, answers}` for a
  /// submission, `{form, outcome: "cancelled", action}` for a cancel press, and
  /// `{form, outcome: "dismissed"}` for a close.
  static func result(of value: ScriptValue) throws -> Result {
    guard case .record(let fields) = value else {
      throw Unreadable(text: "uniterm sent a form's result that is not a record")
    }

    if case .string(let outcome)? = fields["outcome"] {
      switch outcome {
      case "cancelled": return .cancelled
      case "dismissed": return .dismissed
      default: throw Unreadable(text: "uniterm sent the outcome \"\(outcome)\", which is unknown")
      }
    }

    guard case .string(let action)? = fields["action"],
      case .record(let answers)? = fields["answers"]
    else { throw Unreadable(text: "uniterm sent a form's result with no action or answers") }

    return .answered(action: action, answers: answers)
  }

  /// The handle `open-form` returns.
  static func handle(of payload: Data) throws -> UInt64 {
    guard case .integer(let handle) = try ScriptValue.decode(payload) else {
      throw Unreadable(text: "uniterm sent a form handle that is not a number")
    }

    return handle
  }

  // MARK: Values

  /// A value as compact JSON.
  static func json(_ value: ScriptValue) -> String {
    switch value {
    case .null: return "null"
    case .bool(let flag): return flag ? "true" : "false"
    case .integer(let number): return String(number)
    case .number(let number): return decimal(number)
    case .string(let text): return quoted(text)
    case .array(let items): return "[" + items.map(json).joined(separator: ",") + "]"

    case .record(let fields):
      return "{"
        + fields.keys.sorted().map { quoted($0) + ":" + json(fields[$0] ?? .null) }
        .joined(separator: ",") + "}"
    }
  }

  /// What a shorthand prints for its value: a string as it is, a list one entry to a line, and a
  /// number as a number. An unanswered question prints nothing.
  static func lines(of value: ScriptValue) -> [String] {
    switch value {
    case .null: return []
    case .bool(let flag): return [flag ? "true" : "false"]
    case .integer(let number): return [String(number)]
    case .number(let number): return [decimal(number)]
    case .string(let text): return [text]
    case .array(let items): return items.flatMap(lines)
    case .record: return [json(value)]
    }
  }

  /// A number in the fewest digits that read back as the same value, with no fraction for a whole
  /// number below 10^15.
  static func decimal(_ number: Double) -> String {
    if number == number.rounded(), abs(number) < 1e15 { return String(Int64(number)) }

    return "\(number)"
  }

  static func quoted(_ text: String) -> String {
    var out = "\""

    for scalar in text.unicodeScalars {
      switch scalar {
      case "\"": out += "\\\""
      case "\\": out += "\\\\"
      case "\n": out += "\\n"
      case "\r": out += "\\r"
      case "\t": out += "\\t"

      case _ where scalar.value < 0x20:
        out += String(format: "\\u%04x", scalar.value)

      default: out.unicodeScalars.append(scalar)
      }
    }

    return out + "\""
  }

  // MARK: Failures

  /// The exit status for a failure the app reported. Every kind has a code of its own meaning, and
  /// none is 0 or 1, which are answers.
  static func status(for kind: ScriptFailureKind) -> Int32 {
    switch kind {
    case .badArgument: return ScriptHelperMain.Exit.dataError
    case .refused: return ScriptHelperMain.Exit.refused
    case .failed: return ScriptHelperMain.Exit.unavailable
    case .notFound: return ScriptHelperMain.Exit.formEnded
    case .unsupported: return ScriptHelperMain.Exit.protocolMismatch
    case .replyLost: return ScriptHelperMain.Exit.connectionLost
    case .busy: return ScriptHelperMain.Exit.busy
    case .ended: return ScriptHelperMain.Exit.formEnded
    }
  }
}
