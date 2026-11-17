import Theme
import XCTest

@testable import TerminalSurface

final class TerminalConfigTests: XCTestCase {
  /// Catches a palette that stops following the theme tokens. The expected colors are read off the
  /// Catppuccin Latte table by hand: base eff1f5, text 4c4f69, rosewater dc8a78, surface2 acb0be.
  func testLatteConfigCarriesTheThemeColors() throws {
    let lines = try TerminalConfig.make(palette: .latte).render().split(separator: "\n").map(
      String.init)

    XCTAssertTrue(lines.contains("background = #eff1f5"))
    XCTAssertTrue(lines.contains("foreground = #4c4f69"))
    XCTAssertTrue(lines.contains("cursor-color = #dc8a78"))
    XCTAssertTrue(lines.contains("cursor-text = #eff1f5"))
    XCTAssertTrue(lines.contains("selection-background = #acb0be"))
    XCTAssertTrue(lines.contains("selection-foreground = #4c4f69"))
    XCTAssertTrue(lines.contains("palette = 1=#d20f39"))
    XCTAssertTrue(lines.contains("palette = 4=#1e66f5"))
    XCTAssertEqual(lines.filter { $0.hasPrefix("palette = ") }.count, 16)
  }

  /// Mocha: base 1e1e2e, text cdd6f4, rosewater f5e0dc, crust 11111b, surface2 585b70.
  func testMochaConfigCarriesTheThemeColors() throws {
    let lines = try TerminalConfig.make(palette: .mocha).render().split(separator: "\n").map(
      String.init)

    XCTAssertTrue(lines.contains("background = #1e1e2e"))
    XCTAssertTrue(lines.contains("foreground = #cdd6f4"))
    XCTAssertTrue(lines.contains("cursor-color = #f5e0dc"))
    XCTAssertTrue(lines.contains("cursor-text = #11111b"))
    XCTAssertTrue(lines.contains("selection-background = #585b70"))
  }

  /// Catches a config that lets libghostty's own bindings catch Cmd-Z, Cmd-W, Cmd-T, Cmd-D, or
  /// Cmd-Q before uniterm sees them.
  func testConfigClearsBuiltInKeybindings() throws {
    let lines = try TerminalConfig.make(palette: .latte).render().split(separator: "\n").map(
      String.init)

    XCTAssertEqual(lines.filter { $0.hasPrefix("keybind") }, ["keybind = clear"])
  }

  /// Catches a config that drops shell integration or its ssh feature. Without `ssh-env`, an ssh
  /// session to a host without the terminfo entry keeps TERM=xterm-ghostty and breaks.
  func testConfigEnablesShellIntegrationWithSshEnv() throws {
    let lines = try TerminalConfig.make(palette: .latte).render().split(separator: "\n").map(
      String.init)

    XCTAssertTrue(lines.contains("shell-integration = detect"))
    let features = lines.first { $0.hasPrefix("shell-integration-features") }
    XCTAssertEqual(features, "shell-integration-features = cursor,title,path,ssh-env")
  }

  /// The close guard needs `needs_confirm_quit`. A config that turns confirm-close-surface off
  /// would make every close silent.
  func testConfigNeverTurnsOffTheCloseGuard() throws {
    for palette in [ThemePalette.latte, .mocha] {
      let text = try TerminalConfig.make(palette: palette).render()

      XCTAssertTrue(text.contains("confirm-close-surface = true"))
      XCTAssertFalse(text.contains("confirm-close-surface = false"))
      XCTAssertFalse(text.contains("confirm-close-surface = always"))
    }
  }

  func testBuilderRefusesToTurnOffTheCloseGuard() {
    var config = TerminalConfig()

    for value in ["false", "always", "0"] {
      XCTAssertThrowsError(try config.set("confirm-close-surface", value)) {
        XCTAssertEqual($0 as? TerminalConfigError, .unsafeValue(key: "confirm-close-surface"))
      }
    }
  }

  /// Catches a value that can add a line. Each of these would start a second config line, or end
  /// the first one early, in a line-based format.
  func testUnsafeValuesAreRefused() {
    let unsafe = [
      "#fff\nkeybind = super+d=new_split:right",
      "#fff\rcommand = /bin/sh",
      "#fff\u{2028}command = /bin/sh",
      "#fff\u{0085}command = /bin/sh",
      "#fff\u{2029}command = /bin/sh",
      "#fff\u{0B}command = /bin/sh",
      "#fff\u{0C}command = /bin/sh",
      "#fff\0command = /bin/sh",
      "\"quoted\"",
      "back\\slash",
      "two words",
      "tab\there",
      "",
      "\u{1B}[31m",
    ]

    for value in unsafe {
      var config = TerminalConfig()

      XCTAssertThrowsError(
        try config.set("foreground", value), "accepted \(value.debugDescription)"
      ) {
        XCTAssertEqual($0 as? TerminalConfigError, .unsafeValue(key: "foreground"))
      }
      XCTAssertTrue(config.entries.isEmpty)
    }
  }

  /// Keys outside the allow list are refused, whatever the value. They are the ones that would
  /// break the settled decisions: `command`, `term`, `config-file`.
  func testUnknownKeysAreRefused() {
    var config = TerminalConfig()

    for key in ["command", "term", "config-file", "shell-integration-x", ""] {
      XCTAssertThrowsError(try config.set(key, "x")) {
        XCTAssertEqual($0 as? TerminalConfigError, .unknownKey(key))
      }
    }
  }

  /// Catches a config that lets libghostty copy a directory from the last terminal it saw, or that
  /// starts the first pane wherever the app was launched. uniterm passes every directory itself.
  func testDirectoriesAreNeverInheritedAndTheDefaultIsHome() throws {
    let text = try TerminalConfig.make(palette: .mocha).render()
    let lines = Set(text.split(separator: "\n").map(String.init))

    for line in [
      "working-directory = home", "window-inherit-working-directory = false",
      "tab-inherit-working-directory = false", "split-inherit-working-directory = false",
    ] {
      XCTAssertTrue(lines.contains(line), "missing \(line)")
    }
  }

  /// Catches a builder that can be told to turn inheritance back on, or to start somewhere other
  /// than home.
  func testTheDirectoryKeysTakeOnlyTheirSettledValues() {
    var config = TerminalConfig()

    for (key, value) in [
      ("working-directory", "inherit"), ("working-directory", "/tmp"),
      ("window-inherit-working-directory", "true"), ("tab-inherit-working-directory", "true"),
      ("split-inherit-working-directory", "true"),
    ] {
      XCTAssertThrowsError(try config.set(key, value), "\(key) = \(value)") {
        XCTAssertEqual($0 as? TerminalConfigError, .unsafeValue(key: key))
      }
    }
  }

  /// Catches a config that leaves the link match, the OSC 8 links, or the hover preview to
  /// libghostty's defaults. A click shows its target first, so all three must stay on.
  func testLinkMatchingAndPreviewsAreSetExplicitly() throws {
    let text = try TerminalConfig.make(palette: .mocha).render()
    let lines = Set(text.split(separator: "\n").map(String.init))

    for line in ["link-url = true", "link-osc8 = true", "link-previews = true"] {
      XCTAssertTrue(lines.contains(line), "missing \(line)")
    }
  }

  /// Catches a builder that can switch a link feature off, or set the preview to the OSC 8 only
  /// mode, which would hide the target of a plain path.
  func testTheLinkKeysTakeOnlyTrue() {
    var config = TerminalConfig()

    for (key, value) in [
      ("link-url", "false"), ("link-osc8", "false"), ("link-previews", "false"),
      ("link-previews", "osc8"),
    ] {
      XCTAssertThrowsError(try config.set(key, value), "\(key) = \(value)") {
        XCTAssertEqual($0 as? TerminalConfigError, .unsafeValue(key: key))
      }
    }
  }

  /// Every rendered line holds exactly one entry, so the line count is the entry count.
  func testRenderedConfigHasOneLinePerEntry() throws {
    let config = try TerminalConfig.make(palette: .mocha)
    let text = config.render()

    XCTAssertEqual(
      text.split(separator: "\n", omittingEmptySubsequences: false).count, config.entries.count + 1)
    XCTAssertTrue(text.hasSuffix("\n"))
    XCTAssertFalse(text.contains("\r"))
  }
}
