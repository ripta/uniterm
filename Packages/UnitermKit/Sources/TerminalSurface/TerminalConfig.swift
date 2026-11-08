import Foundation
import Theme

public enum TerminalConfigError: Error, Equatable {
  case unknownKey(String)
  case unsafeValue(key: String)
}

/// The config that uniterm hands to libghostty, built entirely from its own settings and theme
/// tokens.
///
/// libghostty reads config only from a file, in a line format. A value that carried a newline could
/// add a line of its own. So the builder takes only keys on an allow list and rejects every value
/// outside a small safe alphabet. It never escapes, because a rejected value cannot be misread.
public struct TerminalConfig: Sendable, Equatable {
  /// The only keys uniterm writes. `confirm-close-surface` is here for `true` only. The inherit keys
  /// are here for `false` only, and `working-directory` for `home` only.
  static let allowedKeys: Set<String> = [
    "background", "foreground", "cursor-color", "cursor-text", "selection-background",
    "selection-foreground", "palette", "keybind", "shell-integration",
    "shell-integration-features", "clipboard-read", "clipboard-write", "confirm-close-surface",
    "working-directory", "window-inherit-working-directory", "tab-inherit-working-directory",
    "split-inherit-working-directory",
  ]

  private static let requiredValues: [String: String] = [
    "confirm-close-surface": "true",
    "working-directory": "home",
    "window-inherit-working-directory": "false",
    "tab-inherit-working-directory": "false",
    "split-inherit-working-directory": "false",
  ]

  private static let safeValueScalars: CharacterSet = {
    var set = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz")
    set.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
    set.insert(charactersIn: "_-.,:/=#+")
    return set
  }()

  public private(set) var entries: [(key: String, value: String)] = []

  public init() {}

  public static func == (lhs: TerminalConfig, rhs: TerminalConfig) -> Bool {
    lhs.entries.elementsEqual(rhs.entries) { $0.key == $1.key && $0.value == $1.value }
  }

  mutating func set(_ key: String, _ value: String) throws {
    guard Self.allowedKeys.contains(key) else {
      throw TerminalConfigError.unknownKey(key)
    }

    guard Self.isSafe(value), !value.isEmpty else {
      throw TerminalConfigError.unsafeValue(key: key)
    }

    if let required = Self.requiredValues[key], value != required {
      throw TerminalConfigError.unsafeValue(key: key)
    }

    entries.append((key, value))
  }

  private static func isSafe(_ value: String) -> Bool {
    value.unicodeScalars.allSatisfy { safeValueScalars.contains($0) }
  }

  /// The file contents. One entry per line.
  public func render() -> String {
    entries.map { "\($0.key) = \($0.value)" }.joined(separator: "\n") + "\n"
  }

  /// The config for one palette. It clears libghostty's built-in key bindings, so every key reaches
  /// uniterm first. It switches off libghostty's working-directory inheritance. It turns on shell
  /// integration with the `ssh-env` feature, which sets a fallback TERM for ssh sessions started
  /// from a shell. That feature's `ssh` wrapper runs uniterm's `ghostty` helper. See
  /// `GhosttyTerminalEngine.launchEnvironment`.
  public static func make(palette: ThemePalette) throws -> TerminalConfig {
    var config = TerminalConfig()
    let colors = palette.terminal

    try config.set("keybind", "clear")
    try config.set("shell-integration", "detect")
    try config.set("shell-integration-features", "cursor,title,path,ssh-env")
    try config.set("confirm-close-surface", "true")

    // A new surface starts where uniterm says, never where libghostty last saw a terminal. The
    // home directory covers a surface that is launched with no directory of its own.
    try config.set("working-directory", "home")
    try config.set("window-inherit-working-directory", "false")
    try config.set("tab-inherit-working-directory", "false")
    try config.set("split-inherit-working-directory", "false")

    // Writes ask so that libghostty sends a Kitty write to the confirm callback, which denies it.
    // OSC 52 writes still go through without a prompt.
    try config.set("clipboard-read", "ask")
    try config.set("clipboard-write", "ask")

    try config.set("background", colors.background.hexString)
    try config.set("foreground", colors.foreground.hexString)
    try config.set("cursor-color", colors.cursor.hexString)
    try config.set("cursor-text", colors.cursorText.hexString)
    try config.set("selection-background", colors.selectionBackground.hexString)
    try config.set("selection-foreground", colors.selectionForeground.hexString)

    for (index, color) in colors.ansi.enumerated() {
      try config.set("palette", "\(index)=\(color.hexString)")
    }

    return config
  }
}
