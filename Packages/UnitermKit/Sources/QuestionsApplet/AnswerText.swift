import Foundation
import QuestionForm

/// Words for what a form was answered with, shown on a resolved tab. It is the user's own answer
/// read back, so it holds nothing the script chose except the question's text.
enum AnswerText {
  static func describe(_ answer: FormAnswer, for question: FormQuestion) -> String {
    switch answer {
    case .unanswered:
      return "No answer"

    case .boolean(let value):
      return value ? "Yes" : "No"

    case .text(let text):
      return text.isEmpty ? "No answer" : text

    case .list(let entries):
      return entries.isEmpty ? "No answer" : entries.joined(separator: ", ")

    case .number(let literal):
      return literal
    }
  }

  /// What a resolved tab says happened, with the requester named.
  static func outcome(_ outcome: FormOutcome, spec: FormSpec, requester: String) -> String {
    switch outcome {
    case .submitted(_, let action, _):
      let label = spec.buttons.first { $0.id == action }?.label ?? action

      return "You chose \u{201C}\(label)\u{201D}. The answers went to \(requester)."

    case .cancelled(let action):
      let label = spec.buttons.first { $0.id == action }?.label ?? action

      return "You chose \u{201C}\(label)\u{201D}. \(requester) was told you cancelled."

    case .dismissed:
      return "This form was closed. \(requester) was told."

    case .ended:
      return "\(requester) closed this form before you answered. Nothing was sent."
    }
  }
}
