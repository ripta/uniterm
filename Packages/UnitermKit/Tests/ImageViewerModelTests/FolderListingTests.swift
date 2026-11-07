import ImageTestSupport
import SourceAccess
import XCTest

@testable import ImageViewerModel

final class FolderListingTests: XCTestCase {
  private var folder: URL!

  override func setUpWithError() throws {
    folder = try ImageFixtures.makeFolder()
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
  }

  private func listing(
    _ sort: ImageSort = .name, types: SupportedImageTypes = SupportedImageTypes()
  )
    throws -> [ListedImage]
  {
    guard case .success(.folder(let opened)) = SourceOpener.open(path: folder.path) else {
      throw XCTSkip("the folder did not open")
    }

    return try opened.list(supporting: types, sort: sort).get()
  }

  /// Catches a byte-order sort. Finder puts `img2` before `img10`, and the folder listing must too.
  func testNameOrderIsFindersAndNumericAware() throws {
    for name in ["img10.png", "img2.png", "img1.png", "Img3.png"] {
      try ImageFixtures.write(ImageFixtures.png(), named: name, in: folder)
    }

    XCTAssertEqual(
      try listing().map(\.name), ["img1.png", "img2.png", "Img3.png", "img10.png"])
  }

  /// Catches hidden files, subfolders, and non-images appearing in the listing. Types are judged by
  /// extension only, and the file's bytes are never read.
  func testOnlyVisibleImageFilesAreListed() throws {
    try ImageFixtures.write(ImageFixtures.png(), named: "a.png", in: folder)
    try ImageFixtures.write(ImageFixtures.png(), named: ".hidden.png", in: folder)
    try ImageFixtures.write(Data("text".utf8), named: "notes.txt", in: folder)
    try ImageFixtures.write(Data("%PDF-1.4".utf8), named: "paper.pdf", in: folder)
    try FileManager.default.createDirectory(
      at: folder.appendingPathComponent("sub.png"), withIntermediateDirectories: false)

    XCTAssertEqual(try listing().map(\.name), ["a.png"])
  }

  /// Catches a type list that includes PDF letting PDF through. The helper may report PDF as a type
  /// it reads, and the viewer still leaves it unopened because PDF is not an image type.
  func testATypeListThatIncludesPDFStillLeavesPDFUnopened() throws {
    let types = SupportedImageTypes(helperTypes: ["public.png", "com.adobe.pdf", "public.jpeg"])

    XCTAssertTrue(types.supports(fileName: "a.png"))
    XCTAssertTrue(types.supports(fileName: "a.jpg"))
    XCTAssertFalse(types.supports(fileName: "a.pdf"))
    XCTAssertFalse(types.supports(fileName: "a.gif"), "a type the helper did not list")
    XCTAssertEqual(
      SupportedImageTypes.imageIdentifiers(from: ["public.png", "com.adobe.pdf", "nonsense"]),
      ["public.png"])

    try ImageFixtures.write(ImageFixtures.png(), named: "a.png", in: folder)
    try ImageFixtures.write(Data("%PDF-1.4".utf8), named: "paper.pdf", in: folder)

    XCTAssertEqual(try listing(types: types).map(\.name), ["a.png"])
  }

  /// Catches date order that is oldest first, or ties that fall out of name order.
  func testDateOrderIsNewestFirstWithTiesInNameOrder() throws {
    for (name, age) in [("old.png", 300.0), ("new.png", 10.0), ("b.png", 100.0), ("a.png", 100.0)] {
      let file = try ImageFixtures.write(ImageFixtures.png(), named: name, in: folder)

      try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000 - age)],
        ofItemAtPath: file.path)
    }

    XCTAssertEqual(
      try listing(.dateModified).map(\.name), ["new.png", "a.png", "b.png", "old.png"])
  }

  /// Catches a landing that leaves the folder when the stored image is gone. The nearest image is
  /// the one that follows its place in the order, or the last when none follows.
  func testNearestLandsOnTheImageAfterAMissingOne() {
    let images = ["a.png", "c.png", "e.png"].map { ListedImage(name: $0, modified: 0) }

    XCTAssertEqual(
      FolderListing.nearest(toName: "c.png", modified: nil, in: images, sort: .name), 1)
    XCTAssertEqual(
      FolderListing.nearest(toName: "b.png", modified: nil, in: images, sort: .name), 1)
    XCTAssertEqual(
      FolderListing.nearest(toName: "z.png", modified: nil, in: images, sort: .name), 2)
    XCTAssertNil(FolderListing.nearest(toName: "a.png", modified: nil, in: [], sort: .name))

    let dated = [
      ListedImage(name: "x", modified: 300), ListedImage(name: "y", modified: 200),
      ListedImage(name: "z", modified: 100),
    ]

    XCTAssertEqual(
      FolderListing.nearest(toName: "gone", modified: 250, in: dated, sort: .dateModified), 1)
  }
}
