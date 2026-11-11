import Foundation

/// What an exec driver runs, as a pane declares it. It is inert: it names a program and runs
/// nothing, and a layout saves it as it is.
///
/// The arguments are literal argv, with an absolute executable first. No shell reads them. The
/// directory is absolute, or nil for the user's home. The environment keys are the names of the
/// variables the driver needs. Their values are never part of a declaration, so a layout never
/// holds one.
public struct ExecDeclaration: Sendable, Hashable {
  public let arguments: [String]
  public let directory: String?
  public let environmentKeys: [String]

  public static let maxArguments = 256
  public static let maxArgumentBytes = 4096
  public static let maxEnvironmentKeys = 64
  public static let maxKeyBytes = 128
  public static let maxValueBytes = 4096

  /// Checks every field. The keys come back sorted, with no repeat.
  public init(arguments: [String], directory: String?, environmentKeys: [String])
    throws(ExecDeclarationError)
  {
    guard let executable = arguments.first, !executable.isEmpty else { throw .noProgram }

    guard executable.hasPrefix("/") else { throw .relativeProgram(executable) }

    guard arguments.count <= Self.maxArguments else { throw .tooMany("arguments") }

    for argument in arguments {
      guard argument.utf8.count <= Self.maxArgumentBytes else { throw .tooLong("an argument") }
      guard !argument.utf8.contains(0) else { throw .nulByte }
    }

    if let directory {
      guard directory.hasPrefix("/") else { throw .relativeDirectory(directory) }
      guard directory.utf8.count <= Self.maxArgumentBytes else { throw .tooLong("the directory") }
      guard !directory.utf8.contains(0) else { throw .nulByte }
    }

    let keys = Array(Set(environmentKeys)).sorted()

    guard keys.count <= Self.maxEnvironmentKeys else { throw .tooMany("environment keys") }

    for key in keys {
      guard Self.isVariableName(key) else { throw .badKey(key) }
    }

    self.arguments = arguments
    self.directory = directory
    self.environmentKeys = keys
  }

  public var executable: String { arguments[0] }

  /// A name is a letter or underscore, then letters, digits, and underscores, as a shell names a
  /// variable.
  public static func isVariableName(_ key: String) -> Bool {
    let bytes = Array(key.utf8)

    guard let first = bytes.first, bytes.count <= maxKeyBytes else { return false }

    func isLetter(_ byte: UInt8) -> Bool {
      (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || byte == 0x5F
    }

    return isLetter(first) && bytes.allSatisfy { isLetter($0) || ($0 >= 0x30 && $0 <= 0x39) }
  }
}

public enum ExecDeclarationError: Error, Sendable, Equatable, CustomStringConvertible {
  case noProgram
  case relativeProgram(String)
  case relativeDirectory(String)
  case badKey(String)
  case nulByte
  case tooLong(String)
  case tooMany(String)
  case missingValue(String)
  case undeclaredValue(String)

  public var description: String {
    switch self {
    case .noProgram: return "the driver names no program"
    case .relativeProgram(let path): return "the program \(path) is not an absolute path"
    case .relativeDirectory(let path): return "the directory \(path) is not an absolute path"
    case .badKey(let key): return "\(key) is not an environment variable name"
    case .nulByte: return "an argument holds a NUL byte"
    case .tooLong(let what): return "\(what) is too long"
    case .tooMany(let what): return "the driver names too many \(what)"
    case .missingValue(let key): return "the driver needs a value for \(key)"
    case .undeclaredValue(let key): return "\(key) is not one of the driver's environment keys"
    }
  }
}

/// One launch, with every input resolved: the declaration, the directory it runs in, and a value
/// for each environment key. An approval for one launch binds exactly these inputs.
public struct ExecLaunch: Sendable, Hashable {
  public let declaration: ExecDeclaration
  public let directory: String
  public let environment: [String: String]

  /// `home` is the directory a declaration with none runs in. Every declared key needs a value,
  /// and a value for a key the declaration does not name is refused.
  public init(declaration: ExecDeclaration, environment: [String: String], home: String)
    throws(ExecDeclarationError)
  {
    for key in declaration.environmentKeys where environment[key] == nil {
      throw .missingValue(key)
    }

    for (key, value) in environment {
      guard declaration.environmentKeys.contains(key) else { throw .undeclaredValue(key) }
      guard value.utf8.count <= ExecDeclaration.maxValueBytes else { throw .tooLong(key) }
      guard !value.utf8.contains(0) else { throw .nulByte }
    }

    self.declaration = declaration
    directory = declaration.directory ?? home
    self.environment = environment
  }

  public var arguments: [String] { declaration.arguments }
}
