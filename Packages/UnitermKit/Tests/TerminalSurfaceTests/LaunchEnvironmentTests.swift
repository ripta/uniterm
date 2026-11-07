import XCTest

@testable import TerminalSurface

/// The engine's choice of `GHOSTTY_BIN_DIR` and `PATH` for every shell. The integration test proves
/// a real shell sees them. These cover the cases it cannot set up: a launch that brings its own
/// value, and a uniterm started with no `PATH` at all.
@MainActor
final class LaunchEnvironmentTests: XCTestCase {
  private let helper = URL(
    fileURLWithPath: "/Applications/uniterm.app/Contents/Resources/ghostty-bin")

  /// Catches a launch whose own variable is replaced by the engine's choice.
  func testALaunchsOwnValuesWin() {
    let environment = GhosttyTerminalEngine.launchEnvironment(
      ["PATH": "/opt/own/bin", "GHOSTTY_BIN_DIR": "/opt/own", "HOME": "/tmp/home"],
      helperDirectory: helper, inheritedPath: "/usr/bin:/bin")

    XCTAssertEqual(
      environment, ["PATH": "/opt/own/bin", "GHOSTTY_BIN_DIR": "/opt/own", "HOME": "/tmp/home"])
  }

  /// Catches a missing `PATH` left to libghostty, which would set it to uniterm's executable
  /// directory alone.
  func testTheHelperAndAPathAreAlwaysSet() {
    XCTAssertEqual(
      GhosttyTerminalEngine.launchEnvironment([:], helperDirectory: helper, inheritedPath: "/a:/b"),
      ["GHOSTTY_BIN_DIR": helper.path, "PATH": "/a:/b"])

    XCTAssertEqual(
      GhosttyTerminalEngine.launchEnvironment([:], helperDirectory: helper, inheritedPath: nil),
      ["GHOSTTY_BIN_DIR": helper.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
  }
}
