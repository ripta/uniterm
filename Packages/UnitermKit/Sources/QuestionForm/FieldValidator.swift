import Foundation

/// What a field's check has decided so far.
public enum FieldState: Equatable, Sendable {
  case valid
  case invalid(String)

  /// A `pattern` check is running. A validating button stays disabled.
  case checking

  /// The `pattern` check timed out, the input was too long, or ICU could not finish. A validating button stays disabled.
  case couldNotCheck
}

/// Checks one field as its value changes, and reports each state to `onChange`.
///
/// The linear checks run on the caller's thread and report at once.
///
/// A `pattern` check runs on the field's own serial queue, so at most one runs per field. The
/// result of the current check reaches `onChange` on `deliveryQueue`.
///
/// A newer value supersedes an older one. The older check is told to stop at its next progress
/// report, and its result is never reported.
public final class FieldValidator: @unchecked Sendable {
  private let question: FormQuestion
  private let limit: TimeInterval
  private let deliveryQueue: DispatchQueue
  private let onChange: @Sendable (FieldState) -> Void
  private let worker: DispatchQueue

  private let lock = NSLock()
  private var generation = 0

  public init(
    question: FormQuestion, limit: TimeInterval = FormLimits.patternTimeLimit,
    deliveryQueue: DispatchQueue = .main, onChange: @escaping @Sendable (FieldState) -> Void
  ) {
    self.question = question
    self.limit = limit
    self.deliveryQueue = deliveryQueue
    self.onChange = onChange
    worker = DispatchQueue(
      label: "uniterm.questionform.pattern.\(question.id)", qos: .userInitiated)
  }

  /// Checks a new value. Call it from one thread, such as the main thread.
  public func update(_ answer: FormAnswer) {
    let current = lock.withLock {
      generation += 1

      return generation
    }

    switch FormChecker.verdict(question, answer) {
    case .valid:
      onChange(.valid)

    case .invalid(let message):
      onChange(.invalid(message))

    case .needsPattern(let text):
      guard let pattern = question.validation.pattern else {
        onChange(.valid)

        return
      }

      onChange(.checking)

      worker.async { [self] in
        guard isCurrent(current) else { return }

        let outcome = pattern.search(text, limit: limit, shouldStop: { !isCurrent(current) })

        guard isCurrent(current) else { return }

        let state: FieldState =
          switch outcome {
          case .matched: .valid
          case .noMatch: .invalid(FormChecker.notMatching)
          case .timedOut, .inputTooLong, .stopped, .failed: .couldNotCheck
          }

        deliveryQueue.async { [self] in
          guard isCurrent(current) else { return }

          onChange(state)
        }
      }
    }
  }

  private func isCurrent(_ value: Int) -> Bool { lock.withLock { generation == value } }
}
