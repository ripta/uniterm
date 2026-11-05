import Foundation

/// Why a source did not load. The text is for the pane, so each case says what to do or what
/// happened, and none of them says "corrupt".
public enum TableLoadError: Error, Equatable, Sendable, LocalizedError {
  case missing(path: String)
  case permissionDenied(path: String)
  case notARegularFile(path: String, kind: String)
  case unsupportedFormat(path: String, description: String, comingLater: Bool)
  case unreadable(path: String, reason: String)

  public var errorDescription: String? {
    switch self {
    case .missing(let path):
      return "\u{201C}\(Self.name(of: path))\u{201D} is missing. It was at \(path)."

    case .permissionDenied(let path):
      return
        "uniterm does not have permission to read \u{201C}\(Self.name(of: path))\u{201D}. "
        + "Allow access to its folder in System Settings > Privacy & Security, then open it again."

    case .notARegularFile(let path, let kind):
      return "\u{201C}\(Self.name(of: path))\u{201D} is \(kind), not a file with data in it."

    case .unsupportedFormat(let path, let description, let comingLater):
      let name = "\u{201C}\(Self.name(of: path))\u{201D} is \(description)."

      return comingLater
        ? "\(name) That format is not supported yet. The data viewer opens CSV and TSV files so far."
        : "\(name) The data viewer does not read that format."

    case .unreadable(let path, let reason):
      return "\u{201C}\(Self.name(of: path))\u{201D} could not be read: \(reason)."
    }
  }

  static func name(of path: String) -> String {
    (path as NSString).lastPathComponent
  }

  /// The error for a failed system call on `path`.
  static func posix(_ code: Int32, path: String) -> TableLoadError {
    switch code {
    case ENOENT, ENOTDIR:
      return .missing(path: path)

    case EACCES, EPERM:
      return .permissionDenied(path: path)

    default:
      return .unreadable(path: path, reason: String(cString: strerror(code)))
    }
  }
}
