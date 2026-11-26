import XCTest

@testable import TerminalSurface

/// The text a new tab shows again, and the launchers that show it. The integration test proves a
/// real shell shows it. These cover what it cannot set up: hostile text, the size limit, every
/// shell name, and paths that cannot be quoted.
final class ScrollbackReplayTests: XCTestCase {
  private var sandbox: URL!

  override func setUp() {
    sandbox = FileManager.default.temporaryDirectory.appending(
      path: "uniterm-replay-\(UUID().uuidString)", directoryHint: .isDirectory)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: sandbox)
  }

  /// Catches saved output that could act as an escape sequence when shown again. Escape, other C0
  /// controls, DEL, and C1 controls go. Newlines, tabs, and other text stay.
  func testControlCharactersAreDroppedAndTextIsKept() {
    let raw = "a\u{1B}]52;c;eA==\u{07}b\tc\r\n\u{9B}31md\u{7F}é\u{0}\n"

    XCTAssertEqual(ScrollbackText.prepared(raw), "a]52;c;eA==b\tc\n31mdé\n")
  }

  /// Catches the screen's empty rows below the prompt reaching the new tab, and output with no
  /// final newline that would run into the new prompt.
  func testTrailingBlankLinesGoAndTheTextEndsInOneNewline() {
    XCTAssertEqual(ScrollbackText.prepared("one\ntwo % \n\n   \n\t\n"), "one\ntwo %\n")
    XCTAssertEqual(ScrollbackText.prepared("only"), "only\n")
  }

  func testTextWithNothingLeftIsNil() {
    XCTAssertNil(ScrollbackText.prepared(""))
    XCTAssertNil(ScrollbackText.prepared("\n \n\t"))
    XCTAssertNil(ScrollbackText.prepared("\u{1B}\u{7}"))
  }

  /// Catches a limit that keeps the oldest output, or one that cuts a line or a character in half.
  func testTextOverTheLimitKeepsItsNewestWholeLines() throws {
    let lines = (1...100).map { "line-\($0)-é" }
    let text = try XCTUnwrap(ScrollbackText.prepared(lines.joined(separator: "\n"), limit: 64))

    XCTAssertLessThanOrEqual(text.utf8.count, 64)
    XCTAssertTrue(text.hasSuffix("line-100-é\n"))
    XCTAssertTrue(text.hasPrefix("line-"), text)
    XCTAssertFalse(text.contains("line-1-é"))
  }

  /// A single line longer than the limit has no whole line to keep.
  func testOneLineOverTheLimitKeepsNothing() {
    XCTAssertNil(ScrollbackText.prepared(String(repeating: "x", count: 100), limit: 10))
  }

  /// Catches a launcher whose name would turn on the wrong shell integration. Each shell that
  /// libghostty integrates gets its own name. Apple's `/bin/bash`, which libghostty skips, and any
  /// other shell get a name that matches none.
  func testLauncherNamesFollowTheShell() {
    XCTAssertEqual(ScrollbackReplay.launcherName(forShell: "/bin/zsh"), "zsh")
    XCTAssertEqual(ScrollbackReplay.launcherName(forShell: "/opt/homebrew/bin/fish"), "fish")
    XCTAssertEqual(ScrollbackReplay.launcherName(forShell: "/opt/homebrew/bin/bash"), "bash")
    XCTAssertEqual(ScrollbackReplay.launcherName(forShell: "/usr/local/bin/nu"), "nu")
    XCTAssertEqual(ScrollbackReplay.launcherName(forShell: "/bin/bash"), "login-shell")
    XCTAssertEqual(ScrollbackReplay.launcherName(forShell: "/bin/tcsh"), "login-shell")
    XCTAssertEqual(ScrollbackReplay.launcherName(forShell: "/bin/sh"), "login-shell")
  }

  /// Catches a path that bash would expand inside libghostty's `exec -l "…"`. A space is safe in
  /// double quotes. A quote, a backslash, a dollar sign, or a backtick is refused.
  func testTheCommandQuotesSafePathsAndRefusesOthers() {
    XCTAssertEqual(
      ScrollbackReplay.command(launcher: URL(fileURLWithPath: "/Users/a/Application Support/zsh")),
      "\"/Users/a/Application Support/zsh\"")

    for bad in ["/a\"b/zsh", "/a\\b/zsh", "/a$HOME/zsh", "/a`id`/zsh"] {
      XCTAssertNil(ScrollbackReplay.command(launcher: URL(fileURLWithPath: bad)), bad)
    }
  }

  /// Catches launchers that cannot run, or that other users could read or change.
  func testLaunchersAreExecutableAndPrivate() throws {
    try ScrollbackReplay.installLaunchers(in: sandbox)

    for name in ScrollbackReplay.launcherNames {
      let path = sandbox.appending(path: name).path
      XCTAssertTrue(FileManager.default.isExecutableFile(atPath: path), name)
      XCTAssertEqual(try permissions(path), 0o700, name)
      XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), ScrollbackReplay.script)
    }

    XCTAssertEqual(try permissions(sandbox.path), 0o700)
  }

  /// Catches saved output that other users could read.
  func testReplayFilesArePrivate() throws {
    let file = try ScrollbackReplay.writeReplayFile("secret\n", in: sandbox)

    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "secret\n")
    XCTAssertEqual(try permissions(file.path), 0o600)
  }

  /// Catches replay files that pile up after sessions that never started, and a sweep that takes a
  /// file a launch is about to show. Launchers are never swept.
  func testOnlyStaleReplayFilesAreRemoved() throws {
    try ScrollbackReplay.installLaunchers(in: sandbox)
    let old = try ScrollbackReplay.writeReplayFile("old\n", in: sandbox)
    let fresh = try ScrollbackReplay.writeReplayFile("fresh\n", in: sandbox)
    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(-ScrollbackReplay.staleAge - 60)],
      ofItemAtPath: old.path)

    ScrollbackReplay.removeStaleFiles(in: sandbox)

    XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: sandbox.appending(path: "zsh").path))
  }

  /// Catches a launcher that leaves its variables for the shell, keeps the file, loses the shell's
  /// arguments, or starts a shell that is not a login shell. A stand-in shell reports what it got.
  func testTheLauncherShowsTheFileThenStartsTheShell() throws {
    try ScrollbackReplay.installLaunchers(in: sandbox)
    let file = try ScrollbackReplay.writeReplayFile("EARLIER-OUTPUT\n", in: sandbox)

    let shell = sandbox.appending(path: "fake-shell")
    try """
    #!/bin/sh
    echo "ARGS:$*"
    echo "FILE:${UNITERM_REPLAY_FILE-unset}:SHELL:${UNITERM_REPLAY_SHELL-unset}"

    """.write(to: shell, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shell.path)

    let process = Process()
    let output = Pipe()
    process.executableURL = sandbox.appending(path: "zsh")
    process.arguments = ["--posix", "-i"]
    process.environment = [
      "PATH": "/usr/bin:/bin",
      ScrollbackReplay.fileVariable: file.path,
      ScrollbackReplay.shellVariable: shell.path,
    ]
    process.standardOutput = output
    try process.run()
    process.waitUntilExit()

    let printed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

    XCTAssertEqual(printed, "EARLIER-OUTPUT\nARGS:--posix -i\nFILE:unset:SHELL:unset\n")
    XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "the launcher kept the file")
  }

  private func permissions(_ path: String) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
  }
}
