import AppletKit
import FileRouting
import XCTest

/// Proves symlinks resolve to their target's kind and type against the system's real database. A
/// fixture type table cannot show this, since the bug was the system answering `public.symlink`
/// for the link itself.
final class SymlinkTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = try makeTemporaryDirectory("symlink")
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: directory)
  }

  private func link(_ name: String, to target: URL) throws -> URL {
    let url = directory.appendingPathComponent(name)
    try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
    return url
  }

  /// Catches a type looked up on the link, which the system calls `public.symlink`.
  func testASymlinkToAFolderAndToATextFileTakeTheirTargetsTypes() throws {
    let folder = directory.appendingPathComponent("real", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

    let text = directory.appendingPathComponent("note.txt")
    try Data("x".utf8).write(to: text)

    let router = FileRouter(declarations: [])

    XCTAssertEqual(
      router.inspect(try link("to-folder", to: folder)),
      .ready(kind: .folder, type: "public.folder", startDirectory: directory.path + "/to-folder"))

    XCTAssertEqual(
      router.inspect(try link("to-text", to: text)),
      .ready(kind: .regularFile, type: "public.plain-text", startDirectory: directory.path))
  }

  /// Catches a start directory taken from the resolved target. A link keeps the path the request
  /// named, as the shell's logical paths do.
  func testStartDirectoryKeepsTheNamedPathNotTheTarget() throws {
    let elsewhere = try makeTemporaryDirectory("elsewhere")
    defer { try? FileManager.default.removeItem(at: elsewhere) }

    let named = try link("proj", to: elsewhere)
    let terminal = applet("terminal", [("public.folder", .owner)])
    let router = FileRouter(declarations: [terminal])

    guard case .open(_, "terminal", let start, _) = router.decide(named) else {
      return XCTFail("expected the terminal")
    }

    XCTAssertEqual(start, named.path)
  }
}
