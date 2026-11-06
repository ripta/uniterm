import Darwin
import Foundation

/// Why a file a viewer was asked to open could not be reached. The text is for the pane, so each
/// case says what happened or what to do, and none of them says "corrupt".
///
/// Every viewer that opens a file shares these cases and their wording. A viewer adds its own
/// errors for what it finds inside the file.
public enum SourceAccessError: Error, Equatable, Sendable, LocalizedError {
  case missing(path: String)

  /// The system refused the read. A folder under Documents or Downloads needs the user's consent in
  /// System Settings, and the refusal surfaces as EACCES or EPERM.
  case permissionDenied(path: String)
  case notARegularFile(path: String, kind: String)
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

    case .unreadable(let path, let reason):
      return "\u{201C}\(Self.name(of: path))\u{201D} could not be read: \(reason)."
    }
  }

  /// The file's name, which messages quote.
  public static func name(of path: String) -> String {
    (path as NSString).lastPathComponent
  }

  /// The error for a failed system call on `path`.
  public static func posix(_ code: Int32, path: String) -> SourceAccessError {
    switch code {
    case ENOENT, ENOTDIR:
      return .missing(path: path)

    case EACCES, EPERM:
      return .permissionDenied(path: path)

    default:
      return .unreadable(path: path, reason: String(cString: strerror(code)))
    }
  }

  /// What a file mode other than a regular file is called in a message.
  public static func kind(of mode: mode_t) -> String {
    switch mode & S_IFMT {
    case S_IFDIR: return "a folder"
    case S_IFIFO: return "a pipe"
    case S_IFCHR, S_IFBLK: return "a device"
    case S_IFSOCK: return "a socket"
    default: return "not a regular file"
    }
  }
}
