import Foundation
import QuestionForm

/// What the user has filled in on one open form, and what each field's check has decided.
///
/// The session owns the rules of timing. A check runs on every change, so a validating button is
/// always current. A field's error shows only after the user left the field or tried to submit,
/// and it clears the moment the field is valid. The views read the session and report to it.
@MainActor
final class FormSession {
  /// What a press of a button does.
  enum Attempt: Equatable {
    case finished(FormOutcome)

    /// The form did not pass. Every error shows now. `firstError` names the first question whose
    /// error shows, in the order the form lists them, or nil when only checks are still running.
    case blocked(firstError: String?)
  }

  let spec: FormSpec
  private(set) var answers: [String: FormAnswer] = [:]
  private(set) var states: [String: FieldState] = [:]

  /// The questions whose errors may show: the failing ones the user left, and every failing one
  /// after a try to submit. A question leaves it as soon as its answer is valid. A valid question
  /// never joins it, so a later mistake in a field stays hidden until the user leaves it again.
  private var revealed: Set<String> = []
  private var validators: [String: FieldValidator] = [:]

  /// Called when any state, error, or answer changes.
  var onChange: () -> Void = {}

  init(spec: FormSpec, limit: TimeInterval = FormLimits.patternTimeLimit) {
    self.spec = spec

    for question in spec.questions {
      answers[question.id] = Self.initialAnswer(question)
      states[question.id] = .checking
    }

    for question in spec.questions {
      let id = question.id

      validators[id] = FieldValidator(question: question, limit: limit) { [weak self] state in
        MainActor.assumeIsolated { self?.record(state, for: id) }
      }
    }

    for question in spec.questions {
      validators[question.id]?.update(answers[question.id] ?? .unanswered)
    }
  }

  /// What a question holds before the user touches it: its default, or nothing.
  static func initialAnswer(_ question: FormQuestion) -> FormAnswer {
    switch question.type {
    case .boolean(let value):
      return value.map(FormAnswer.boolean) ?? .unanswered

    case .choice(_, _, let value):
      return value.map(FormAnswer.text) ?? .unanswered

    case .multi(_, let value):
      return value.map(FormAnswer.list) ?? .unanswered

    case .string(let value), .text(_, let value), .color(let value):
      return value.map(FormAnswer.text) ?? .unanswered

    case .integer(let value), .number(let value):
      return value.map { FormAnswer.number($0.literal) } ?? .unanswered

    case .file:
      return .unanswered
    }
  }

  func answer(for id: String) -> FormAnswer {
    answers[id] ?? .unanswered
  }

  /// Records what a widget now holds and starts its check.
  func set(_ answer: FormAnswer, for id: String) {
    guard answers[id] != nil else { return }

    answers[id] = answer
    validators[id]?.update(answer)
    onChange()
  }

  private func record(_ state: FieldState, for id: String) {
    states[id] = state

    if state == .valid { revealed.remove(id) }

    onChange()
  }

  /// The user left a question's field.
  func leave(_ id: String) {
    guard let state = states[id], state != .valid, !revealed.contains(id) else { return }

    revealed.insert(id)
    onChange()
  }

  /// The message that shows beside a question, or nil when none shows now.
  func shownError(for id: String) -> String? {
    guard revealed.contains(id), let state = states[id] else { return nil }

    switch state {
    case .invalid(let message): return message
    case .couldNotCheck: return FormChecker.couldNotCheck
    case .valid, .checking: return nil
    }
  }

  /// True when every question's check has passed.
  var isValid: Bool {
    spec.questions.allSatisfy { states[$0.id] == .valid }
  }

  /// Whether a button may be pressed. A button that validates waits for every question to pass.
  func isEnabled(_ button: FormButton) -> Bool {
    button.role == .cancel || !button.validates || isValid
  }

  /// The first question, in form order, whose check failed.
  var firstFailingQuestion: String? {
    spec.questions.first {
      switch states[$0.id] {
      case .invalid, .couldNotCheck: return true
      default: return false
      }
    }?.id
  }

  /// Presses a button. A cancel button and a button that does not validate finish the form at
  /// once. A validating button finishes it only when every question passes. Otherwise every error
  /// shows, and the first failing question is named so focus can go there.
  func press(_ button: FormButton) -> Attempt {
    if button.role == .cancel { return .finished(.cancelled(action: button.id)) }

    if button.validates && !isValid {
      revealed.formUnion(spec.questions.map(\.id).filter { states[$0] != .valid })
      onChange()

      return .blocked(firstError: firstFailingQuestion)
    }

    return .finished(.submitted(submission: 1, action: button.id, answers: answers))
  }
}
