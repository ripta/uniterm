import Darwin
import ImageTestSupport
import SourceAccess
import XCTest

@testable import ImageViewerModel

final class SourceOpenerTests: XCTestCase {
  private var folder: URL!

  override func setUpWithError() throws {
    folder = try ImageFixtures.makeFolder()
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
  }

  /// Catches a named pipe blocking the worker. The open is non-blocking, so it returns at once with
  /// the regular-file refusal, and no reader ever has to appear on the other end.
  func testANamedPipeIsRefusedWithoutBlocking() async throws {
    let fifo = folder.appendingPathComponent("pipe.png").path
    XCTAssertEqual(mkfifo(fifo, 0o600), 0)

    let result = await Task.detached { SourceOpener.open(path: fifo) }.value

    guard case .failure(.notARegularFile(_, let kind)) = result else {
      return XCTFail("a pipe was accepted: \(result)")
    }

    XCTAssertEqual(kind, "a pipe")
  }

  /// Catches a symlink to a pipe passing as a file. The check reads the opened descriptor, which is
  /// the pipe, whatever the path looked like.
  func testASymlinkToAPipeIsRefused() throws {
    let fifo = folder.appendingPathComponent("pipe").path
    let link = folder.appendingPathComponent("link.png").path
    XCTAssertEqual(mkfifo(fifo, 0o600), 0)
    try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: fifo)

    guard case .failure(.notARegularFile) = SourceOpener.open(path: link) else {
      return XCTFail("a symlinked pipe was accepted")
    }
  }

  /// Catches the regular-file check running on the path. A file opened as a regular file stays one
  /// when its path is replaced by a pipe afterwards, and the descriptor still reads the original.
  /// The check is on the descriptor, so a swap after it cannot change what the helper receives.
  func testTheCheckIsOnTheDescriptorNotThePath() throws {
    let file = folder.appendingPathComponent("a.png")
    try ImageFixtures.png().write(to: file)

    guard case .success(.file(let opened)) = SourceOpener.open(path: file.path) else {
      return XCTFail("a regular file was refused")
    }

    try FileManager.default.removeItem(at: file)
    XCTAssertEqual(mkfifo(file.path, 0o600), 0)

    var bytes = [UInt8](repeating: 0, count: 4)

    XCTAssertEqual(pread(opened.descriptor, &bytes, 4, 0), 4)
    XCTAssertEqual(bytes, [0x89, 0x50, 0x4E, 0x47])
    XCTAssertEqual(opened.size, ImageFixtures.png().count)
  }

  /// Catches a folder listing that follows the path after the folder was opened. The listing and
  /// the files come from the descriptor, so replacing the path with another folder changes neither.
  func testAFolderListsAndOpensThroughItsDescriptor() throws {
    try ImageFixtures.write(ImageFixtures.png(), named: "mine.png", in: folder)

    guard case .success(.folder(let opened)) = SourceOpener.open(path: folder.path) else {
      return XCTFail("a folder was refused")
    }

    let moved = folder.deletingLastPathComponent().appendingPathComponent("moved")
    try FileManager.default.moveItem(at: folder, to: moved)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    try ImageFixtures.write(ImageFixtures.png(), named: "theirs.png", in: folder)
    defer { try? FileManager.default.removeItem(at: moved) }

    XCTAssertEqual(
      try opened.list(supporting: SupportedImageTypes(), sort: .name).get().map(\.name),
      ["mine.png"])

    guard case .success = opened.openFile(named: "mine.png") else {
      return XCTFail("the file in the opened folder was not found")
    }

    guard case .failure = opened.openFile(named: "../theirs.png") else {
      return XCTFail("a name with a slash was opened")
    }
  }

  /// Catches a missing path reporting anything but the shared missing-file message.
  func testAMissingPathIsReportedAsMissing() {
    guard
      case .failure(.missing) = SourceOpener.open(path: folder.appendingPathComponent("no").path)
    else { return XCTFail("a missing path was not reported missing") }
  }
}
