import Foundation

/// Checks answers against a question's rules.
///
/// Every keyword but `pattern` runs here in time linear in the answer, which a hard byte cap
/// bounds. `pattern` runs through `PatternProgram`, off the main thread. `FieldValidator` joins
/// the two for a widget.
public enum FormChecker {
  /// What a question's answer needs from `pattern`, once the linear checks pass.
  public enum Verdict: Equatable, Sendable {
    case valid

    /// The linear checks fail, with the message to show.
    case invalid(String)

    /// The linear checks pass. The text must still match the question's pattern.
    case needsPattern(String)
  }

  public static let required = "This question needs an answer."
  public static let couldNotCheck = "Could not check this answer."
  public static let notMatching = "Does not match the required format."

  /// The result of the checks that run in linear time.
  public static func verdict(_ question: FormQuestion, _ answer: FormAnswer) -> Verdict {
    let answered = isAnswered(answer)

    guard answered else { return question.isRequired ? .invalid(required) : .valid }

    switch (question.type, answer) {
    case (.boolean, .boolean):
      return .valid

    case (.choice(let choices, let allowsOther, _), .text(let text)):
      if choices.contains(text) { return .valid }

      guard allowsOther else { return .invalid("Choose one of the listed choices.") }

      return text.utf8.count <= FormLimits.maxOtherBytes
        ? .valid : .invalid("Keep this under \(FormLimits.maxOtherBytes) bytes.")

    case (.multi(let choices, _), .list(let entries)):
      guard Set(entries).count == entries.count, entries.allSatisfy(choices.contains) else {
        return .invalid("Choose from the listed choices, each once.")
      }

      return count(entries.count, question.validation)

    case (.string, .text(let text)):
      guard !text.contains(where: \.isNewline) else { return .invalid("Use one line.") }

      return string(text, question)

    case (.text, .text(let text)):
      return string(text, question)

    case (.integer, .number(let literal)):
      return number(literal, question, whole: true)

    case (.number, .number(let literal)):
      return number(literal, question, whole: false)

    case (.color, .text(let text)):
      return normalizedColor(text) == nil ? .invalid("Use a color such as #1a2b3c.") : .valid

    case (.file(_, let multiple, _), .list(let paths)) where multiple:
      guard paths.allSatisfy(isPath) else { return .invalid("A path is empty or too long.") }

      guard paths.count <= FormLimits.maxFilePaths else {
        return .invalid("Pick at most \(FormLimits.maxFilePaths) files.")
      }

      return count(paths.count, question.validation)

    case (.file(_, let multiple, _), .text(let path)) where !multiple:
      return isPath(path) ? .valid : .invalid("A path is empty or too long.")

    default:
      return .invalid("This answer is not the kind this question takes.")
    }
  }

  /// Checks a whole form's answers and blocks while a `pattern` runs, at most its time limit
  /// each. A caller on the main thread must not use it. The widgets use `FieldValidator`.
  public static func check(
    _ spec: FormSpec, answers: [String: FormAnswer],
    limit: TimeInterval = FormLimits.patternTimeLimit
  ) -> FormErrors {
    var errors = FormErrors()

    for question in spec.questions {
      switch verdict(question, answers[question.id] ?? .unanswered) {
      case .valid:
        break

      case .invalid(let message):
        errors.messages[question.id] = message

      case .needsPattern(let text):
        guard let pattern = question.validation.pattern else { break }

        switch pattern.search(text, limit: limit) {
        case .matched: break
        case .noMatch: errors.messages[question.id] = notMatching
        case .timedOut, .inputTooLong, .stopped, .failed:
          errors.messages[question.id] = couldNotCheck
        }
      }
    }

    return errors
  }

  /// The color as `#rrggbbaa` in lowercase, or nil when it is not `#rrggbb` or `#rrggbbaa`.
  public static func normalizedColor(_ text: String) -> String? {
    let digits = Array(text.utf8)

    guard digits.first == 0x23, digits.count == 7 || digits.count == 9,
      digits.dropFirst().allSatisfy({
        (0x30...0x39).contains($0) || (0x41...0x46).contains($0) || (0x61...0x66).contains($0)
      })
    else { return nil }

    let lowered = text.lowercased()

    return digits.count == 7 ? lowered + "ff" : lowered
  }

  private static func isAnswered(_ answer: FormAnswer) -> Bool {
    switch answer {
    case .unanswered: return false
    case .boolean, .number: return true
    case .text(let text): return !text.isEmpty
    case .list(let entries): return !entries.isEmpty
    }
  }

  private static func isPath(_ path: String) -> Bool {
    !path.isEmpty && path.utf8.count <= FormLimits.maxPathBytes && !path.utf8.contains(0)
  }

  private static func count(_ count: Int, _ validation: FormValidation) -> Verdict {
    if let minimum = validation.minItems, count < minimum {
      return .invalid("Choose at least \(minimum).")
    }

    if let maximum = validation.maxItems, count > maximum {
      return .invalid("Choose at most \(maximum).")
    }

    return .valid
  }

  private static func string(_ text: String, _ question: FormQuestion) -> Verdict {
    guard text.utf8.count <= question.answerByteLimit else {
      return .invalid("Keep this under \(question.answerByteLimit) bytes.")
    }

    // JSON Schema counts code points, so a combining mark and an emoji each count as one.
    let length = text.unicodeScalars.count

    if let minimum = question.validation.minLength, length < minimum {
      return .invalid("Use at least \(minimum) characters.")
    }

    if let maximum = question.validation.maxLength, length > maximum {
      return .invalid("Use at most \(maximum) characters.")
    }

    return question.validation.pattern == nil ? .valid : .needsPattern(text)
  }

  private static func number(_ literal: String, _ question: FormQuestion, whole: Bool) -> Verdict {
    guard let value = ExactDecimal(literal: literal) else { return .invalid("Enter a number.") }

    if whole {
      guard value.isWhole else { return .invalid("Enter a whole number.") }

      guard value.wholeNumber != nil else { return .invalid("That number is too large.") }
    }

    let validation = question.validation

    if let minimum = validation.minimum, value < minimum {
      return .invalid("Use \(minimum.literal) or more.")
    }

    if let maximum = validation.maximum, value > maximum {
      return .invalid("Use \(maximum.literal) or less.")
    }

    if let bound = validation.exclusiveMinimum, value <= bound {
      return .invalid("Use more than \(bound.literal).")
    }

    if let bound = validation.exclusiveMaximum, value >= bound {
      return .invalid("Use less than \(bound.literal).")
    }

    if let step = validation.multipleOf, !value.isMultiple(of: step) {
      return .invalid("Use a multiple of \(step.literal).")
    }

    return .valid
  }
}
