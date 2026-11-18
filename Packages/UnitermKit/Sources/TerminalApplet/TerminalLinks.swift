import Darwin
import Foundation
import SourceAccess

/// Why a click on a path opened nothing. The text goes to the pane's status bar.
enum TerminalLinkRefusal: Equatable {
  /// The path is relative, or starts with `~`. It could name another file than the one that was
  /// printed, since the output may come from another host or from before a `cd`.
  case relative

  /// A `file:` link that names a host other than this one.
  case otherHost

  /// Text that is not a plain local path, such as control characters or a query on a file link.
  case notPlain

  /// The pane holds output that a remote client may have written.
  case remoteOutput

  /// The link text changed between the hover and the click.
  case changed

  /// The path leads to another file than the one shown, or through a link.
  case differs

  /// Nothing opens at the path, or it is not a file or a folder.
  case unavailable

  /// An earlier click in this tab is still being checked.
  case stillChecking

  var message: String {
    switch self {
    case .relative:
      return
        "Not opened: a relative path may not name the file that printed it. Use an absolute path."

    case .otherHost:
      return "Not opened: that link names another host."

    case .notPlain:
      return "Not opened: that link is not a plain local path."

    case .remoteOutput:
      return "Not opened: this output may be from another host."

    case .changed:
      return "Not opened: the link changed after it was shown."

    case .differs:
      return "Not opened: that path leads to a different file than the one shown."

    case .unavailable:
      return "Not opened: nothing there can be opened."

    case .stillChecking:
      return "Not opened: a previous click is still being checked."
    }
  }
}

/// What a link's text names. A program chose the text, so nothing here touches the file system.
enum TerminalLinkTarget: Equatable {
  /// An absolute local path, as it would open. A `file:` link is shown as its decoded path.
  case file(String)

  /// A path that a click refuses.
  case refused(TerminalLinkRefusal)

  /// A web address or another scheme. A click on it does nothing.
  case notAFile

  static func classify(_ text: String) -> TerminalLinkTarget {
    guard !text.isEmpty else { return .notAFile }

    if let scheme = scheme(of: text) {
      guard scheme.lowercased() == "file" else { return .notAFile }

      return fileLink(text)
    }

    guard text.hasPrefix("/") else { return .refused(.relative) }

    return plain(text)
  }

  private static func scheme(of text: String) -> String? {
    guard let colon = text.firstIndex(of: ":") else { return nil }

    let candidate = text[..<colon]

    guard let first = candidate.unicodeScalars.first, first.isASCII, first.properties.isAlphabetic
    else { return nil }

    let allowed = CharacterSet(
      charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+-.")

    guard candidate.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }

    return String(candidate)
  }

  /// A `file:` link opens only when its host is empty or `localhost`. The path is decoded, and a
  /// query, a fragment, or credentials make the link something other than a path.
  private static func fileLink(_ text: String) -> TerminalLinkTarget {
    guard let components = URLComponents(string: text), components.query == nil,
      components.fragment == nil, components.user == nil, components.password == nil,
      components.port == nil
    else { return .refused(.notPlain) }

    let host = components.host ?? ""

    guard host.isEmpty || host.lowercased() == "localhost" else { return .refused(.otherHost) }

    let path = components.path

    guard path.hasPrefix("/") else { return .refused(.relative) }

    return plain(path)
  }

  /// The overlay shows the path as it is, so a path that would show as something else is refused.
  /// Control and format characters can hide or reorder text, and line and paragraph separators
  /// can break the line.
  private static func plain(_ path: String) -> TerminalLinkTarget {
    for scalar in path.unicodeScalars {
      switch scalar.properties.generalCategory {
      case .control, .format, .lineSeparator, .paragraphSeparator, .unassigned, .surrogate:
        return .refused(.notPlain)

      default:
        continue
      }
    }

    return .file(path)
  }

  /// The prefixes macOS keeps as links into `/private`. The system reports the real path of an
  /// opened file under `/private`, so the printed spelling is brought to the same form before the
  /// two are compared.
  static let privateAliases = ["/tmp", "/var", "/etc"]

  static func normalized(_ path: String) -> String {
    var result = path

    while result.count > 1 && result.hasSuffix("/") { result.removeLast() }

    for alias in privateAliases where result == alias || result.hasPrefix(alias + "/") {
      return "/private" + result
    }

    return result
  }
}

/// Checks that an absolute path still names the file the pane showed, by opening it.
///
/// The open does not follow a final link, does not block, and never takes a controlling terminal.
/// The path of the opened descriptor is then read back from the system. It must equal the shown
/// path after the `/private` aliases are applied. A printed link to another file therefore opens
/// nothing, and neither does a path that goes through a link to another folder.
///
/// The open touches a path a program printed. It runs only after the user clicked the target that
/// was shown, and never on the main thread.
enum LinkClickVerifier {
  /// Runs the check on a background queue.
  static func verify(_ path: String) async -> TerminalLinkRefusal? {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(returning: check(path))
      }
    }
  }

  /// Nil when the path is the file or folder it shows. The caller is off the main thread.
  static func check(_ path: String) -> TerminalLinkRefusal? {
    var before = stat()

    guard lstat(path, &before) == 0 else { return .unavailable }

    switch before.st_mode & S_IFMT {
    case S_IFREG, S_IFDIR:
      break

    case S_IFLNK:
      return .differs

    default:
      return .unavailable
    }

    let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY | O_CLOEXEC)

    guard descriptor >= 0 else { return errno == ELOOP ? .differs : .unavailable }

    defer { close(descriptor) }

    var after = stat()

    guard fstat(descriptor, &after) == 0 else { return .unavailable }

    guard after.st_dev == before.st_dev, after.st_ino == before.st_ino,
      after.st_mode & S_IFMT == before.st_mode & S_IFMT
    else { return .differs }

    guard let real = DescriptorPath.read(descriptor) else { return .unavailable }

    return TerminalLinkTarget.normalized(real) == TerminalLinkTarget.normalized(path)
      ? nil : .differs
  }
}
