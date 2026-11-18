import Foundation
import XCTest

@testable import ScriptRuntime

/// What the `open` command does before it connects: how it reads its arguments, and how it makes a
/// relative path absolute. It cannot prove the app's side or the real working directory, which
/// `ScriptOpenRunTests` runs through the built command.
final class ScriptOpenCommandTests: XCTestCase {
  /// Catches an option that is read as a path, a path that is read as an option, and a command
  /// that runs with nothing to open.
  func testArgumentsAreReadAsOptionsThenPaths() {
    XCTAssertEqual(
      ScriptOpenCommand.parse(["--socket", "/s", "a", "/b"]),
      .open(.init(socket: "/s", paths: ["a", "/b"])))
    XCTAssertEqual(
      ScriptOpenCommand.parse(["--", "-odd", "--socket"]),
      .open(.init(socket: nil, paths: ["-odd", "--socket"])))
    XCTAssertEqual(ScriptOpenCommand.parse(["-h"]), .help)

    for bad in [[], ["--socket"], ["--socket", "/s"], ["--nope", "a"]] {
      guard case .usage = ScriptOpenCommand.parse(bad) else {
        return XCTFail("\(bad) was accepted")
      }
    }
  }

  /// Catches a join that looks at the target or tidies it. A relative path is the working
  /// directory, a slash, and the argument as typed. Dots stay, since only the kernel knows what a
  /// link on the way makes of them. An absolute path is sent as it is. The directory is read once,
  /// and not at all when every path is absolute.
  func testARelativePathIsJoinedToTheDirectoryAsTyped() throws {
    var reads = 0

    let resolved = try ScriptOpenCommand.resolve(
      ["notes.md", "../up/x", "/abs/y", "dir/", "./z"],
      directory: {
        reads += 1
        return "/work/here"
      })

    XCTAssertEqual(
      resolved,
      ["/work/here/notes.md", "/work/here/../up/x", "/abs/y", "/work/here/dir/", "/work/here/./z"])
    XCTAssertEqual(reads, 1)

    _ = try ScriptOpenCommand.resolve(
      ["/only/absolute"],
      directory: {
        XCTFail("the directory was read for an absolute path")
        return "/"
      })

    XCTAssertEqual(
      try ScriptOpenCommand.resolve(["x"], directory: { "/" }), ["/x"],
      "a root directory doubled its slash")
  }

  /// Catches a path the command cannot name faithfully. An empty argument, and one with a
  /// replacement character where invalid UTF-8 was, are refused with a usage status, since sending
  /// either would name a different file than the user typed.
  func testAnArgumentThatCannotBeNamedIsRefused() {
    for bad in ["", "/caf\u{FFFD}"] {
      XCTAssertThrowsError(try ScriptOpenCommand.resolve([bad], directory: { "/" })) { error in
        XCTAssertEqual(
          (error as? ScriptOpenCommand.Problem)?.status, ScriptHelperMain.Exit.usage, "\(bad)")
      }
    }
  }

  /// Catches a deleted working directory that is sent on as a path. The failure is the command's,
  /// with its own status and no connection.
  func testADeletedWorkingDirectoryFailsInTheCommand() {
    let status = ScriptOpenCommand.run(
      arguments: ["relative.txt"], environment: [:],
      directory: {
        throw ScriptOpenCommand.Problem(
          text: "gone", status: ScriptHelperMain.Exit.noInput)
      })

    XCTAssertEqual(status, ScriptHelperMain.Exit.noInput)
  }
}
