import Foundation
import ScriptWire

/// What a widget holds for one question, before it is checked. A number stays the literal the
/// user typed, so a check compares it as a decimal.
public enum FormAnswer: Equatable, Sendable {
  case unanswered
  case boolean(Bool)

  /// A `string`, `text`, `choice`, `color`, or single `file` answer.
  case text(String)

  /// A `multi` or multiple `file` answer.
  case list([String])
  case number(String)
}

/// The messages of the fields that failed, keyed by question `id`, as
/// `{"errors": {"<id>": "<message>"}}`.
public struct FormErrors: Equatable, Sendable {
  public var messages: [String: String]

  public init(messages: [String: String] = [:]) { self.messages = messages }

  public var isEmpty: Bool { messages.isEmpty }

  public var scriptValue: ScriptValue {
    .record(["errors": .record(messages.mapValues { .string($0) })])
  }
}

/// How a form ended, and the value the waiting script receives.
public enum FormOutcome: Equatable, Sendable {
  case submitted(submission: Int, action: String, answers: [String: FormAnswer])

  /// The cancel button was pressed. It is not a submission and carries no answers.
  case cancelled(action: String)

  /// The form's tab or pane closed.
  case dismissed

  /// The run ended, authority was revoked, or the connection closed. Nothing was submitted.
  ///
  /// A script never receives this as a result. The host fails the pending wait as ended, so
  /// `scriptValue` is nil.
  case ended

  public func scriptValue(form handle: UInt64, spec: FormSpec) -> ScriptValue? {
    let form = ScriptValue.integer(min(handle, ScriptProtocol.maxID))

    switch self {
    case .submitted(let submission, let action, let answers):
      return .record([
        "form": form,
        "submission": .integer(UInt64(min(max(submission, 0), Int(ScriptProtocol.maxID)))),
        "action": .string(FormAnswerValue.clipped(action, limit: FormLimits.maxIDBytes)),
        "answers": FormAnswerValue.answers(spec: spec, answers: answers),
      ])

    case .cancelled(let action):
      return .record([
        "form": form, "outcome": .string("cancelled"),
        "action": .string(FormAnswerValue.clipped(action, limit: FormLimits.maxIDBytes)),
      ])

    case .dismissed:
      return .record(["form": form, "outcome": .string("dismissed")])

    case .ended:
      return nil
    }
  }
}

/// Turns the answers of a submission into script values. An unanswered question is `null`.
///
/// Every cap holds here, whatever the caller passes. A button that does not validate may submit
/// an answer that fails its question's rules, and the value is then as close as the type allows.
/// A string is cut at a character boundary at its byte limit. A list keeps its first entries up
/// to the entry limit. A color that does not read, and a number that does not read or does not
/// fit the type, become `null`. So no answer is ever cut later by the reply encoder.
enum FormAnswerValue {
  static func answers(spec: FormSpec, answers: [String: FormAnswer]) -> ScriptValue {
    var fields: [String: ScriptValue] = [:]

    for question in spec.questions {
      fields[question.id] = value(question, answers[question.id] ?? .unanswered)
    }

    return .record(fields)
  }

  static func value(_ question: FormQuestion, _ answer: FormAnswer) -> ScriptValue {
    switch (question.type, answer) {
    case (.boolean, .boolean(let flag)):
      return .bool(flag)

    case (.integer, .number(let literal)):
      guard let decimal = ExactDecimal(literal: literal), decimal.wholeNumber != nil else {
        return .null
      }

      return number(decimal)

    case (.number, .number(let literal)):
      return ExactDecimal(literal: literal).map(number) ?? .null

    case (.color, .text(let text)):
      return FormChecker.normalizedColor(text).map { .string($0) } ?? .null

    case (.multi, .list(let entries)):
      let kept = entries.prefix(question.answerEntryLimit).map {
        clipped($0, limit: FormLimits.maxChoiceBytes)
      }

      return kept.isEmpty ? .null : .array(kept.map { .string($0) })

    case (.file(_, let multiple, _), .list(let entries)):
      return paths(entries, multiple: multiple, question)

    case (.file(_, let multiple, _), .text(let path)):
      return paths([path], multiple: multiple, question)

    case (.string, .text(let text)), (.text, .text(let text)), (.choice, .text(let text)):
      let kept = clipped(text, limit: question.answerByteLimit)

      return kept.isEmpty ? .null : .string(kept)

    default:
      return .null
    }
  }

  private static func paths(_ entries: [String], multiple: Bool, _ question: FormQuestion)
    -> ScriptValue
  {
    let kept = entries.prefix(question.answerEntryLimit).map {
      clipped($0, limit: FormLimits.maxPathBytes)
    }.filter { !$0.isEmpty }

    guard let first = kept.first else { return .null }

    return multiple ? .array(kept.map { .string($0) }) : .string(first)
  }

  private static func number(_ decimal: ExactDecimal) -> ScriptValue {
    if let whole = decimal.wholeNumber {
      return whole >= 0 ? .integer(UInt64(whole)) : .number(Double(whole))
    }

    let double = decimal.doubleValue

    return double.isFinite ? .number(double) : .null
  }

  static func clipped(_ text: String, limit: Int) -> String {
    var kept = ""
    var bytes = 0

    for scalar in text.unicodeScalars {
      bytes += String(scalar).utf8.count

      if bytes > limit { break }

      kept.unicodeScalars.append(scalar)
    }

    return kept
  }
}
