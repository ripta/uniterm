import ImageTestSupport
import SourceAccess
import XCTest

@testable import ImageViewerModel

final class SourceLoaderTests: XCTestCase {
  private var folder: URL!

  override func setUpWithError() throws {
    folder = try ImageFixtures.makeFolder()
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
  }

  private func load(
    _ url: URL, bookmark: Data? = nil, kind: SourceKind? = nil, wanted: WantedImage? = nil
  ) -> Result<LoadedSource, SourceLoadFailure> {
    SourceLoader.loadBlocking(
      path: url.path, bookmark: bookmark, storedKind: kind, wanted: wanted, sort: .name,
      types: SupportedImageTypes())
  }

  /// Catches a folder that opens on anything but its first image in Finder order.
  func testAFolderOpensOnItsFirstImage() throws {
    for name in ["img10.png", "img2.png"] {
      try ImageFixtures.write(ImageFixtures.png(), named: name, in: folder)
    }

    let loaded = try load(folder).get()

    XCTAssertEqual(loaded.kind, .folder)
    XCTAssertEqual(loaded.index, 0)
    XCTAssertEqual(loaded.file?.name, "img2.png")
    XCTAssertEqual(loaded.listing.count, 2)
    XCTAssertNotNil(loaded.resolved.bookmark)
  }

  /// Catches a single file that is not an image being opened on the strength of its bytes. The type
  /// comes from the extension, so a text file named `.txt` is refused without being read.
  func testAFileThatIsNotAnImageIsRefusedByItsExtension() throws {
    let text = try ImageFixtures.write(Data("hello".utf8), named: "notes.txt", in: folder)

    guard case .failure(.notAnImage(let name)) = load(text) else {
      return XCTFail("a text file was accepted")
    }

    XCTAssertEqual(name, "notes.txt")
  }

  /// Catches an empty folder showing a blank pane. The failure says the folder has no images.
  func testAFolderWithNoImagesIsAFailureThatSaysSo() throws {
    try ImageFixtures.write(Data("x".utf8), named: "a.txt", in: folder)

    guard case .failure(let failure) = load(folder) else {
      return XCTFail("an empty folder opened")
    }

    XCTAssertEqual(failure, .noImages(folder: folder.path))
    XCTAssertTrue(failure.localizedDescription.contains("no images"))
  }

  /// Catches a restore that forgets which image was showing. The stored name comes back when it is
  /// there, and the next image in order comes back when it is gone.
  func testARestoreLandsOnTheStoredImageOrTheNearestOne() throws {
    for name in ["a.png", "c.png", "e.png"] {
      try ImageFixtures.write(ImageFixtures.png(), named: name, in: folder)
    }

    XCTAssertEqual(
      try load(folder, wanted: WantedImage(name: "c.png", modified: nil)).get().file?.name, "c.png")
    XCTAssertEqual(
      try load(folder, wanted: WantedImage(name: "d.png", modified: nil)).get().file?.name, "e.png")
  }

  /// Catches a stored folder that is now a file being opened as if nothing changed. The stored kind
  /// decides, and a mismatch reports what changed.
  func testASourceOfAnotherKindThanStoredIsReported() throws {
    let file = try ImageFixtures.write(ImageFixtures.png(), named: "a.png", in: folder)

    guard case .failure(.kindChanged(_, let expected)) = load(file, kind: .folder) else {
      return XCTFail("a file passed for a folder")
    }

    XCTAssertEqual(expected, .folder)
  }

  /// Catches a moved source not being found. The path is gone, so the bookmark finds the folder,
  /// and the result says where.
  func testAMovedFolderIsFoundByItsBookmark() throws {
    try ImageFixtures.write(ImageFixtures.png(), named: "a.png", in: folder)

    let first = try load(folder).get()
    let moved = folder.deletingLastPathComponent().appendingPathComponent("renamed")
    try FileManager.default.moveItem(at: folder, to: moved)
    defer { try? FileManager.default.removeItem(at: moved) }

    let again = try load(folder, bookmark: first.resolved.bookmark, kind: .folder).get()

    XCTAssertEqual(
      again.resolved.movedFrom.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
      moved.resolvingSymlinksInPath().path)
    XCTAssertEqual(again.file?.name, "a.png")
  }

  /// Catches the bookmark winning over a new file at the stored path. The path is what the user
  /// named, so a different file there wins and the bookmark is made again for it.
  func testANewFileAtTheStoredPathWinsAndTheBookmarkIsRemade() throws {
    let file = try ImageFixtures.write(ImageFixtures.png(), named: "a.png", in: folder)
    let first = try load(file).get()

    try FileManager.default.removeItem(at: file)
    try ImageFixtures.write(ImageFixtures.png(width: 10, height: 10), named: "a.png", in: folder)

    let again = try load(file, bookmark: first.resolved.bookmark, kind: .file).get()

    XCTAssertNil(again.resolved.movedFrom)
    XCTAssertNotEqual(again.resolved.bookmark, first.resolved.bookmark)
  }
}
