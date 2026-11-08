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

  /// Catches a load that waits for the whole listing, or that guesses an image for a fresh folder.
  /// A folder opened fresh comes back with its handle and no image, since only the scan can say
  /// which image is first. The bookmark is made at load.
  func testAFreshFolderLoadsWithoutChoosingAnImage() throws {
    for name in ["img10.png", "img2.png"] {
      try ImageFixtures.write(ImageFixtures.png(), named: name, in: folder)
    }

    let loaded = try load(folder).get()

    XCTAssertEqual(loaded.kind, .folder)
    XCTAssertNotNil(loaded.folder)
    XCTAssertNil(loaded.image)
    XCTAssertFalse(loaded.folderNotListed)
    XCTAssertNotNil(loaded.resolved.bookmark)
  }

  /// Catches a single file that cannot step. Its folder is opened for the scan, and the file is the
  /// image to show at once.
  func testASingleFileOpensItsFolderForTheScanAndShowsItselfAtOnce() throws {
    let file = try ImageFixtures.write(ImageFixtures.png(), named: "b.png", in: folder)
    try ImageFixtures.write(ImageFixtures.png(), named: "a.png", in: folder)

    let loaded = try load(file).get()

    XCTAssertEqual(loaded.kind, .file)
    XCTAssertEqual(loaded.image?.name, "b.png")
    XCTAssertNotNil(loaded.folder)
    XCTAssertFalse(loaded.folderNotListed)
  }

  /// Catches a folder that cannot be opened leaving an empty pane. A folder with no read bit still
  /// lets the file inside be opened by name, so the load shows the file and says the folder was not
  /// listed. This is what macOS privacy protection looks like to the app.
  func testAFileInAFolderThatCannotBeListedStillLoadsAndSaysSo() throws {
    let file = try ImageFixtures.write(ImageFixtures.png(), named: "a.png", in: folder)

    XCTAssertEqual(chmod(folder.path, 0o311), 0)
    defer { chmod(folder.path, 0o755) }

    let loaded = try load(file).get()

    XCTAssertEqual(loaded.image?.name, "a.png")
    XCTAssertNil(loaded.folder)
    XCTAssertTrue(loaded.folderNotListed)
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

  /// Catches a folder with no images being listed as if it had some. The load itself succeeds, and
  /// its listing is empty, which the pane reports once the scan ends.
  func testAFolderWithNoImagesListsNothing() throws {
    try ImageFixtures.write(Data("x".utf8), named: "a.txt", in: folder)

    let loaded = try load(folder).get()

    XCTAssertEqual(
      try loaded.folder?.list(supporting: SupportedImageTypes(), sort: .name).get(), [])
    XCTAssertTrue(
      SourceLoadFailure.noImages(folder: folder.path).localizedDescription.contains("no images"))
  }

  /// Catches a restore that waits for the listing before showing an image it can open at once. The
  /// stored name is opened straight from the folder. A name that is gone comes back with no image,
  /// so the pane waits for the scan and lands on the nearest one.
  func testARestoreOpensTheStoredImageAtOnceOrLeavesTheChoiceToTheScan() throws {
    for name in ["a.png", "c.png", "e.png"] {
      try ImageFixtures.write(ImageFixtures.png(), named: name, in: folder)
    }

    XCTAssertEqual(
      try load(folder, wanted: WantedImage(name: "c.png", modified: nil)).get().image?.name, "c.png"
    )
    XCTAssertNil(try load(folder, wanted: WantedImage(name: "d.png", modified: nil)).get().image)
  }

  /// Catches a restore of a single file that lands on the file instead of the image the user had
  /// stepped to. The stored file is a sibling of the current image, and the current image wins.
  func testARestoredFileOpensTheCurrentImageOfItsFolder() throws {
    let stored = try ImageFixtures.write(ImageFixtures.png(), named: "a.png", in: folder)
    try ImageFixtures.write(ImageFixtures.png(), named: "c.png", in: folder)

    let loaded = try load(stored, kind: .file, wanted: WantedImage(name: "c.png", modified: nil))
      .get()

    XCTAssertEqual(loaded.image?.name, "c.png")
    XCTAssertEqual(loaded.kind, .file)
  }

  /// Catches a single-file restore that gives up when the stored file is gone. After the path and
  /// the bookmark both fail, the old folder is tried for the current image, and the result says the
  /// source moved there.
  func testARestoreFallsBackToTheOldFolderForTheCurrentImage() throws {
    let stored = try ImageFixtures.write(ImageFixtures.png(), named: "a.png", in: folder)
    try ImageFixtures.write(ImageFixtures.png(), named: "c.png", in: folder)

    try FileManager.default.removeItem(at: stored)

    let loaded = try load(stored, kind: .file, wanted: WantedImage(name: "c.png", modified: nil))
      .get()

    XCTAssertEqual(loaded.image?.name, "c.png")
    XCTAssertEqual(
      loaded.resolved.movedFrom.map { URL(fileURLWithPath: $0).lastPathComponent }, "c.png")
    XCTAssertNotNil(loaded.folder)
  }

  /// Catches the fallback running when it should not. With no image remembered, or a folder source,
  /// a missing path is a plain failure.
  func testAMissingSourceIsAFailureWhenThereIsNoOldFolderImageToFind() throws {
    let stored = try ImageFixtures.write(ImageFixtures.png(), named: "a.png", in: folder)

    try FileManager.default.removeItem(at: stored)

    guard case .failure(.access) = load(stored, kind: .file, wanted: nil) else {
      return XCTFail("a missing file opened")
    }

    guard
      case .failure(.access) = load(
        stored, kind: .file, wanted: WantedImage(name: "gone.png", modified: nil))
    else { return XCTFail("a missing sibling opened") }
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

    let again = try load(
      folder, bookmark: first.resolved.bookmark, kind: .folder,
      wanted: WantedImage(name: "a.png", modified: nil)
    ).get()

    XCTAssertEqual(
      again.resolved.movedFrom.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
      moved.resolvingSymlinksInPath().path)
    XCTAssertEqual(again.image?.name, "a.png")
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
