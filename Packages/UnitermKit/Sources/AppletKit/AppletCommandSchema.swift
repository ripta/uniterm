import Foundation

/// The shape of one value an applet command or event carries. Shared dispatch checks a command's
/// arguments against it before the applet sees them, so an applet never handles a value it did not
/// declare.
public indirect enum AppletValueSchema: Sendable, Equatable {
  /// A string of at most `maxBytes` UTF-8 bytes.
  case string(maxBytes: Int)

  /// A whole number from `minimum` to `maximum`, both included.
  case integer(minimum: Int, maximum: Int)

  /// A finite number from `minimum` to `maximum`, both included.
  case number(minimum: Double, maximum: Double)

  case boolean

  /// A string that is one of the names listed.
  case choice([String])

  /// At most `maxCount` values of one shape.
  case array(of: AppletValueSchema, maxCount: Int)

  case object(AppletObjectSchema)
}

/// The fields of an object value. A field the schema does not name is refused, so a newer caller's
/// extra field is never silently ignored.
public struct AppletObjectSchema: Sendable, Equatable {
  public struct Field: Sendable, Equatable {
    public let schema: AppletValueSchema
    public let isRequired: Bool

    public init(_ schema: AppletValueSchema, required: Bool = true) {
      self.schema = schema
      isRequired = required
    }
  }

  public let fields: [String: Field]

  public init(_ fields: [String: Field] = [:]) {
    self.fields = fields
  }

  public static let empty = AppletObjectSchema()
}

/// One command or event: its name, what it carries, and an example a driver author can copy.
public struct AppletMessageSchema: Sendable, Equatable {
  public let name: String
  public let summary: String
  public let arguments: AppletObjectSchema
  public let example: JSONValue

  public init(
    name: String, summary: String, arguments: AppletObjectSchema = .empty,
    example: JSONValue = .object([:])
  ) {
    self.name = name
    self.summary = summary
    self.arguments = arguments
    self.example = example
  }
}

/// The commands an applet type takes and the events it emits, under one schema version. A caller
/// names the type and the version it was written for, and a mismatch is refused before any effect.
public struct AppletCommandSchema: Sendable, Equatable {
  public let appletType: String
  public let version: Int
  public let commands: [AppletMessageSchema]
  public let events: [AppletMessageSchema]

  public init(
    appletType: String, version: Int, commands: [AppletMessageSchema],
    events: [AppletMessageSchema]
  ) {
    self.appletType = appletType
    self.version = version
    self.commands = commands
    self.events = events
  }

  public func command(named name: String) -> AppletMessageSchema? {
    commands.first { $0.name == name }
  }

  public func event(named name: String) -> AppletMessageSchema? {
    events.first { $0.name == name }
  }
}

/// Why a command did not run. The code lets a caller tell its own mistake from a refusal. The
/// message is for a person, and never names a pane other than the target.
public struct AppletCommandError: Error, Sendable, Equatable {
  public enum Code: String, Sendable, Equatable, CaseIterable {
    /// The target pane runs another applet type than the command names.
    case unsupportedApplet = "unsupported-applet"

    /// The target applet does not speak the schema version the command names.
    case unsupportedVersion = "unsupported-version"

    case unknownCommand = "unknown-command"
    case badArgument = "bad-argument"

    /// The caller may not command the target now, or the target takes no commands.
    case refused

    /// The target is not open.
    case notFound = "not-found"

    /// Too many commands wait for the target. Nothing was dropped: this one was refused whole.
    case busy

    /// The applet failed while it ran the command, and changed nothing.
    case failed
  }

  public let code: Code
  public let message: String

  public init(_ code: Code, _ message: String) {
    self.code = code
    self.message = message
  }
}

extension AppletValueSchema {
  /// Throws a bad-argument error that names the path to the first value that does not fit.
  public func validate(_ value: JSONValue, at path: String) throws(AppletCommandError) {
    switch (self, value) {
    case (.string(let maxBytes), .string(let text)):
      guard text.utf8.count <= maxBytes else {
        throw AppletCommandError(
          .badArgument, "\(path) is \(text.utf8.count) bytes, and the most is \(maxBytes)")
      }

    case (.integer(let minimum, let maximum), .number(let number)):
      guard number.isFinite, number == number.rounded(), number >= Double(minimum),
        number <= Double(maximum)
      else {
        throw AppletCommandError(
          .badArgument, "\(path) must be a whole number from \(minimum) to \(maximum)")
      }

    case (.number(let minimum, let maximum), .number(let number)):
      guard number.isFinite, number >= minimum, number <= maximum else {
        throw AppletCommandError(
          .badArgument, "\(path) must be a number from \(minimum) to \(maximum)")
      }

    case (.boolean, .bool):
      return

    case (.choice(let names), .string(let text)):
      guard names.contains(text) else {
        throw AppletCommandError(
          .badArgument, "\(path) must be one of \(names.joined(separator: ", "))")
      }

    case (.array(let element, let maxCount), .array(let values)):
      guard values.count <= maxCount else {
        throw AppletCommandError(
          .badArgument, "\(path) holds \(values.count) values, and the most is \(maxCount)")
      }

      for (index, value) in values.enumerated() {
        try element.validate(value, at: "\(path)[\(index)]")
      }

    case (.object(let schema), .object(let fields)):
      try schema.validate(fields, at: path)

    default:
      throw AppletCommandError(.badArgument, "\(path) must be \(kindName)")
    }
  }

  private var kindName: String {
    switch self {
    case .string: return "a string"
    case .integer: return "a whole number"
    case .number: return "a number"
    case .boolean: return "true or false"
    case .choice: return "a string"
    case .array: return "an array"
    case .object: return "an object"
    }
  }
}

extension AppletObjectSchema {
  /// Checks every field. A field the schema does not name, or a required one that is missing, is a
  /// bad argument.
  public func validate(_ value: [String: JSONValue], at path: String) throws(AppletCommandError) {
    for key in value.keys.sorted() where fields[key] == nil {
      throw AppletCommandError(.badArgument, "\(path) has no field \"\(key)\"")
    }

    for (key, field) in fields.sorted(by: { $0.key < $1.key }) {
      guard let fieldValue = value[key] else {
        if field.isRequired {
          throw AppletCommandError(.badArgument, "\(path) needs the field \"\(key)\"")
        }

        continue
      }

      try field.schema.validate(fieldValue, at: "\(path).\(key)")
    }
  }
}
