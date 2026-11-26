import Darwin
import Foundation

/// Prepares terminal output that a new tab shows again.
public enum ScrollbackText {
  /// The most UTF-8 bytes a saved scrollback keeps. A longer one keeps its newest lines.
  public static let limit = 1 << 20

  /// The text as a new tab shows it, or nil when nothing is left.
  ///
  /// Control characters other than newline and tab are dropped, so the text can never act as an
  /// escape sequence. Trailing blank lines go, and the text ends in one newline. Text over the limit
  /// keeps its newest whole lines.
  public static func prepared(_ raw: String, limit: Int = ScrollbackText.limit) -> String? {
    var scalars = String.UnicodeScalarView()

    for scalar in raw.unicodeScalars where isKept(scalar) {
      scalars.append(scalar)
    }

    var text = String(scalars)

    while let last = text.unicodeScalars.last, last == "\n" || last == "\t" || last == " " {
      text.unicodeScalars.removeLast()
    }

    guard !text.isEmpty else { return nil }

    text += "\n"

    let bytes = Array(text.utf8)
    guard bytes.count > limit else { return text }

    let tail = bytes.suffix(limit)
    let start =
      tail.firstIndex(of: UInt8(ascii: "\n")).map { tail.index(after: $0) } ?? tail.endIndex
    let kept = String(decoding: tail[start...], as: UTF8.self)

    return kept.isEmpty ? nil : kept
  }

  private static func isKept(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x0A, 0x09: return true
    case 0x00...0x1F, 0x7F...0x9F: return false
    default: return true
    }
  }
}

/// Starts a login shell that first shows saved output.
///
/// libghostty has no call that puts output on a surface. Only the child can print into the pty.
/// So the tab runs a launcher that prints the saved file, deletes it, and then becomes the user's
/// login shell.
///
/// libghostty picks shell integration from the base name of the command. Each launcher is named
/// after the shell it starts, such as `zsh`, so integration applies as it does without a replay.
/// `/bin/bash` gets no integration from libghostty, so its launcher has a name that matches none.
enum ScrollbackReplay {
  static let fileVariable = "UNITERM_REPLAY_FILE"
  static let shellVariable = "UNITERM_REPLAY_SHELL"

  /// A launcher whose name gets no shell integration.
  static let plainLauncher = "login-shell"

  static let launcherNames = ["bash", "elvish", "fish", "nu", "zsh", plainLauncher]

  /// Replay files older than this are left over from a launch that never ran its launcher.
  static let staleAge: TimeInterval = 600

  /// Runs under `/bin/bash`, as libghostty's own login step does. It unsets its variables, so the
  /// shell and its programs never see them. `exec -a` gives the shell a login name, as libghostty's
  /// `exec -l` does.
  static let script = """
    #!/bin/bash
    # Written by uniterm. Shows a restored terminal tab's earlier output, then starts the login shell.
    file=$\(fileVariable)
    shell=$\(shellVariable)
    unset \(fileVariable) \(shellVariable)
    if [ -n "$file" ]; then
      [ -f "$file" ] && cat -- "$file"
      rm -f -- "$file"
    fi
    [ -n "$shell" ] || shell=/bin/zsh
    exec -a "-${shell##*/}" "$shell" "$@"

    """

  /// The launcher for a shell. `/bin/bash` is Apple's, which libghostty's integration skips.
  static func launcherName(forShell path: String) -> String {
    let name = (path as NSString).lastPathComponent

    guard path != "/bin/bash", launcherNames.contains(name) else { return plainLauncher }

    return name
  }

  /// The user's login shell, as libghostty picks it for a desktop launch: the passwd entry, then
  /// `SHELL`.
  static func loginShellPath() -> String {
    if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
      let path = String(cString: shell)
      if !path.isEmpty { return path }
    }

    if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty { return shell }

    return "/bin/zsh"
  }

  /// The command libghostty runs, or nil when the path cannot be quoted safely. libghostty runs it
  /// inside `bash -c "exec -l …"`, so the path must hold nothing that bash expands in quotes.
  static func command(launcher: URL) -> String? {
    let path = launcher.path

    guard !path.contains(where: { "\"\\$`".contains($0) }) else { return nil }

    return "\"\(path)\""
  }

  /// Writes every launcher into `directory`, which is private to the user. Each write replaces the
  /// file in one rename, so a launch never runs half a script.
  static func installLaunchers(in directory: URL) throws {
    try makePrivateDirectory(directory)

    for name in launcherNames {
      let target = directory.appending(path: name)
      try write(Data(script.utf8), to: target, mode: 0o700)
    }
  }

  /// Writes the text for one launch. The launcher deletes the file once it has shown it.
  static func writeReplayFile(_ text: String, in directory: URL) throws -> URL {
    try makePrivateDirectory(directory)

    let file = directory.appending(path: "replay-\(UUID().uuidString).txt")
    try write(Data(text.utf8), to: file, mode: 0o600)
    return file
  }

  /// Deletes replay files that no launcher took, such as after a session failed to start.
  static func removeStaleFiles(in directory: URL, now: Date = Date()) {
    let manager = FileManager.default
    let names = (try? manager.contentsOfDirectory(atPath: directory.path)) ?? []

    for name in names where name.hasPrefix("replay-") {
      let url = directory.appending(path: name)
      let modified = (try? manager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date

      if let modified, now.timeIntervalSince(modified) > staleAge {
        try? manager.removeItem(at: url)
      }
    }
  }

  private static func makePrivateDirectory(_ directory: URL) throws {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
  }

  private static func write(_ data: Data, to target: URL, mode: mode_t) throws {
    let temp = target.deletingLastPathComponent().appending(
      path: ".\(target.lastPathComponent).\(UUID().uuidString).tmp")

    let descriptor = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, mode)
    guard descriptor >= 0 else {
      throw TerminalConfigStoreError.posix(operation: "open", code: errno)
    }

    var offset = 0
    let failure: Int32? = data.withUnsafeBytes { buffer in
      while offset < buffer.count {
        let written = Darwin.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
        if written < 0 {
          if errno == EINTR { continue }
          return errno
        }
        offset += written
      }
      return nil
    }

    close(descriptor)

    if let failure {
      unlink(temp.path)
      throw TerminalConfigStoreError.posix(operation: "write", code: failure)
    }

    guard rename(temp.path, target.path) == 0 else {
      let code = errno
      unlink(temp.path)
      throw TerminalConfigStoreError.posix(operation: "rename", code: code)
    }
  }
}
