import XCTest

@testable import TableData

/// How a stored path and bookmark become the file to open.
final class SourceResolverTests: XCTestCase {
  private func bookmark(of file: URL) throws -> Data {
    try file.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
  }

  private func resolve(_ path: String, _ bookmark: Data?) throws -> ResolvedSource {
    try SourceResolver.resolveBlocking(path: path, bookmark: bookmark).get()
  }

  /// Catches a path that opens a file and no bookmark made for it. A fresh open makes a bookmark
  /// that names the file.
  func testAnOpenMakesABookmarkThatNamesTheFile() throws {
    let scratch = try Scratch(self)
    let file = try scratch.write("a.csv", "a\n")

    let resolved = try resolve(file.path, nil)

    XCTAssertEqual(resolved.file.path, file.path)
    XCTAssertNil(resolved.movedFrom)

    var stale = false
    let named = try URL(
      resolvingBookmarkData: try XCTUnwrap(resolved.bookmark), options: [.withoutUI],
      relativeTo: nil, bookmarkDataIsStale: &stale)
    XCTAssertEqual(named.resolvingSymlinksInPath().path, file.path)
  }

  /// Catches a moved file that reports missing, and a stored path that is not replaced by the new
  /// one. The path is gone, the bookmark finds the file, and the result says where.
  func testAMovedFileIsFoundThroughItsBookmark() throws {
    let scratch = try Scratch(self)
    let old = try scratch.write("old.csv", "a\n")
    let stored = try bookmark(of: old)
    let new = scratch.url.appendingPathComponent("new.csv")
    try FileManager.default.moveItem(at: old, to: new)

    let resolved = try resolve(old.path, stored)

    XCTAssertEqual(resolved.file.resolvingSymlinksInPath().path, new.path)
    XCTAssertEqual(
      resolved.movedFrom.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }, new.path)
  }

  /// Catches a bookmark that wins over the path. A renderer rotates `out.csv` away and writes a new
  /// one. The stored bookmark follows the old file, and the path must win. The bookmark is remade
  /// for the new file, so a later rename of it is found.
  func testANewFileAtTheStoredPathWinsAndTheBookmarkIsRemade() throws {
    let scratch = try Scratch(self)
    let path = scratch.url.appendingPathComponent("out.csv")
    try Data("old\n".utf8).write(to: path)
    let stale = try bookmark(of: path)

    let rotated = scratch.url.appendingPathComponent("out.1.csv")
    try FileManager.default.moveItem(at: path, to: rotated)
    try Data("new\n".utf8).write(to: path)

    let resolved = try resolve(path.path, stale)

    XCTAssertEqual(resolved.file.path, path.path)
    XCTAssertNil(resolved.movedFrom)
    XCTAssertNotEqual(resolved.bookmark, stale)

    let renamed = scratch.url.appendingPathComponent("renamed.csv")
    try FileManager.default.moveItem(at: path, to: renamed)

    let found = try resolve(path.path, resolved.bookmark)
    XCTAssertEqual(found.file.resolvingSymlinksInPath().path, renamed.path)
  }

  /// Catches a bookmark that is remade on every open for the same file, which rewrites the layout
  /// for nothing. A bookmark that names the file is kept.
  func testABookmarkThatNamesTheFileIsKept() throws {
    let scratch = try Scratch(self)
    let file = try scratch.write("a.csv", "a\n")
    let first = try resolve(file.path, nil)

    let again = try resolve(file.path, first.bookmark)

    XCTAssertEqual(again.bookmark, first.bookmark)
  }

  /// Catches a missing file with no bookmark, or with a bookmark to a deleted file, that crashes or
  /// shows a vague error. Both say the file is missing and where it was.
  func testAMissingFileReportsMissing() throws {
    let scratch = try Scratch(self)
    let file = try scratch.write("a.csv", "a\n")
    let stored = try bookmark(of: file)
    try FileManager.default.removeItem(at: file)

    for data in [nil, stored] {
      switch SourceResolver.resolveBlocking(path: file.path, bookmark: data) {
      case .success:
        XCTFail("a deleted file resolved")

      case .failure(let error):
        XCTAssertEqual(error, .missing(path: file.path))
      }
    }
  }
}
