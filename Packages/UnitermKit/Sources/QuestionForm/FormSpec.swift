import Foundation

/// A form a script asks the user. Only `FormSpecReader` builds one from untrusted input, so a
/// value of this type has passed every cap and every rule of the spec.
public struct FormSpec: Equatable, Sendable {
  public var title: String?
  public var items: [FormItem]
  public var buttons: [FormButton]

  public init(title: String?, items: [FormItem], buttons: [FormButton]) {
    self.title = title
    self.items = items
    self.buttons = buttons
  }

  public var questions: [FormQuestion] {
    items.compactMap {
      if case .question(let question) = $0 { return question }

      return nil
    }
  }

  /// The buttons of a form that names none: OK as the primary and Cancel as the cancel.
  public static let defaultButtons = [
    FormButton(id: "ok", label: "OK", role: .primary, validates: true),
    FormButton(id: "cancel", label: "Cancel", role: .cancel, validates: false),
  ]
}

public enum FormItem: Equatable, Sendable {
  case question(FormQuestion)
  case block(FormBlock)
}

/// Display-only content. It has no answer and no number.
public enum FormBlock: Equatable, Sendable {
  case paragraph(String)
  case list([String])
  case code(String)

  /// Key and value pairs, in the order the spec gives them.
  case table([FormTableRow])
  case notice(level: FormNoticeLevel, text: String)
}

public struct FormTableRow: Equatable, Sendable {
  public let key: String
  public let value: String

  public init(key: String, value: String) {
    self.key = key
    self.value = value
  }
}

public enum FormNoticeLevel: String, Sendable, CaseIterable {
  case info
  case warning
  case danger
}

public enum FormButtonRole: String, Sendable, CaseIterable {
  case primary
  case normal
  case cancel
  case destructive
}

public struct FormButton: Equatable, Sendable {
  public let id: String
  public let label: String
  public let role: FormButtonRole

  /// Whether the button checks the form before it submits. A cancel button never does.
  public let validates: Bool

  public init(id: String, label: String, role: FormButtonRole, validates: Bool) {
    self.id = id
    self.label = label
    self.role = role
    self.validates = validates
  }
}

public enum FormFileMode: String, Sendable, CaseIterable {
  case open
  case directory
  case save
}

/// What a question collects. Each case carries what only its type has.
public enum FormQuestionType: Equatable, Sendable {
  case boolean(defaultValue: Bool?)
  case choice(choices: [String], allowsOther: Bool, defaultValue: String?)
  case multi(choices: [String], defaultValue: [String]?)
  case string(defaultValue: String?)
  case text(multiline: Bool, defaultValue: String?)
  case integer(defaultValue: ExactDecimal?)
  case number(defaultValue: ExactDecimal?)

  /// An sRGB color, as `#rrggbbaa`.
  case color(defaultValue: String?)
  case file(mode: FormFileMode, multiple: Bool, types: [String])

  public var name: String {
    switch self {
    case .boolean: return "boolean"
    case .choice: return "choice"
    case .multi: return "multi"
    case .string: return "string"
    case .text: return "text"
    case .integer: return "integer"
    case .number: return "number"
    case .color: return "color"
    case .file: return "file"
    }
  }
}

/// The validation keywords of one question. A keyword the question's type does not take is
/// refused when the spec is read, so every field set here applies.
public struct FormValidation: Equatable, Sendable {
  public var minLength: Int?
  public var maxLength: Int?
  public var pattern: PatternProgram?
  public var minimum: ExactDecimal?
  public var maximum: ExactDecimal?
  public var exclusiveMinimum: ExactDecimal?
  public var exclusiveMaximum: ExactDecimal?
  public var multipleOf: ExactDecimal?
  public var minItems: Int?
  public var maxItems: Int?

  public init() {}
}

public struct FormQuestion: Equatable, Sendable {
  public let id: String
  public let text: String
  public let detail: String?
  public let isRequired: Bool
  public let placeholder: String?
  public let type: FormQuestionType
  public let validation: FormValidation

  public init(
    id: String, text: String, detail: String? = nil, isRequired: Bool = false,
    placeholder: String? = nil, type: FormQuestionType,
    validation: FormValidation = FormValidation()
  ) {
    self.id = id
    self.text = text
    self.detail = detail
    self.isRequired = isRequired
    self.placeholder = placeholder
    self.type = type
    self.validation = validation
  }

  /// The longest answer a widget may hold, in UTF-8 bytes, for a question whose answer is one
  /// string. A hard cap, so an answer is never cut on its way to the script. A `maxLength` below
  /// the type's cap lowers it, at four bytes a character.
  public var answerByteLimit: Int {
    switch type {
    case .string:
      return Self.limit(FormLimits.maxStringAnswerBytes, characters: validation.maxLength)
    case .text:
      return Self.limit(FormLimits.maxTextAnswerBytes, characters: validation.maxLength)
    case .choice(let choices, let allowsOther, _):
      return allowsOther
        ? FormLimits.maxOtherBytes : choices.map { $0.utf8.count }.max() ?? 0
    case .color: return 9
    case .file: return FormLimits.maxPathBytes
    case .boolean, .multi, .integer, .number: return 0
    }
  }

  /// The most entries a `multi` or `file` answer may hold.
  public var answerEntryLimit: Int {
    switch type {
    case .multi(let choices, _): return min(validation.maxItems ?? choices.count, choices.count)
    case .file(_, let multiple, _):
      return multiple
        ? min(validation.maxItems ?? FormLimits.maxFilePaths, FormLimits.maxFilePaths) : 1
    default: return 1
    }
  }

  private static func limit(_ cap: Int, characters: Int?) -> Int {
    guard let characters else { return cap }

    return min(cap, characters * 4)
  }
}
