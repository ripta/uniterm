import Darwin
import Foundation

/// What kind of thing a path names, found without opening it.
public enum FileKind: Sendable, Equatable {
  case regularFile
  case folder
}

/// Why a path was not routed.
public enum RouteRefusal: Error, Sendable, Equatable {
  /// The path does not exist, or a symlink on it dangles.
  case missing

  /// The system could not be asked about the path.
  case unreadable

  /// A FIFO, a device node, or a socket. The router never opens one, since opening a FIFO can
  /// block and opening a device can have side effects.
  case special(kind: String)

  /// No applet declares the file's type. The type is nil when the system gave none.
  case unsupported(type: String?)

  /// More than one applet claims the type equally, and the caller has no way to ask.
  case ambiguous(type: String, applets: [String])

  /// The sentence a window posts, naming the file and its type where there is one.
  public func message(for file: URL) -> String {
    let name = "\u{201C}\(file.lastPathComponent)\u{201D}"

    switch self {
    case .missing:
      return "\(name) does not exist."

    case .unreadable:
      return "\(name) could not be read."

    case .special(let kind):
      return "\(name) is \(kind), which uniterm does not open."

    case .unsupported(let type):
      return "uniterm has no applet that opens \(name), whose type is \(type ?? "unknown")."

    case .ambiguous(let type, let applets):
      let names = applets.joined(separator: ", ")
      return "\(name) has type \(type), which more than one applet opens equally: \(names)."
    }
  }
}

/// The result of looking at a path before routing it.
public enum FileInspection: Sendable, Equatable {
  case ready(kind: FileKind, type: String, startDirectory: String)
  case refused(RouteRefusal)
}

enum PathInspector {
  /// Classifies a path with `lstat`, and `stat` after a symlink. Neither opens the path, so a FIFO
  /// or a device on it is classified and never blocked on. This can still wait on a slow network
  /// volume, so callers run it off the main thread.
  static func kind(of url: URL) -> Result<FileKind, RouteRefusal> {
    var info = stat()

    guard lstat(url.path, &info) == 0 else {
      return .failure(errno == ENOENT || errno == ENOTDIR ? .missing : .unreadable)
    }

    if info.st_mode & S_IFMT == S_IFLNK {
      guard stat(url.path, &info) == 0 else {
        return .failure(
          errno == ENOENT || errno == ENOTDIR || errno == ELOOP ? .missing : .unreadable)
      }
    }

    switch info.st_mode & S_IFMT {
    case S_IFREG: return .success(.regularFile)
    case S_IFDIR: return .success(.folder)
    case S_IFIFO: return .failure(.special(kind: "a FIFO"))
    case S_IFCHR, S_IFBLK: return .failure(.special(kind: "a device"))
    case S_IFSOCK: return .failure(.special(kind: "a socket"))
    default: return .failure(.special(kind: "not a regular file or folder"))
    }
  }

  /// The folder a routed pane starts in: the folder itself, or the file's own folder.
  static func startDirectory(of url: URL, kind: FileKind) -> String {
    switch kind {
    case .folder: return url.path
    case .regularFile: return url.deletingLastPathComponent().path
    }
  }
}
