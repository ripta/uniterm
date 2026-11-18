import ImageTestSupport
import SourceAccess
import XCTest

@testable import ImageViewerModel

/// A folder a controller named, opened through its read scope. The pane lists it and opens members
/// from it, and none of that may look at a file outside the scope.
final class ScopedFolderTests: XCTestCase {
  private var root: URL!
  private var folder: URL!
  private var scope: ReadScope!

  override func setUpWithError() throws {
    let made = try ImageFixtures.makeFolder("scope")
    let real = try XCTUnwrap(realpath(made.path, nil).map { String(cString: $0) })

    folder = URL(fileURLWithPath: real)
    root = folder.deletingLastPathComponent()

    let outside = root.appendingPathComponent("outside", isDirectory: true)

    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try ImageFixtures.write(ImageFixtures.png(), named: "a.png", in: folder)
    try ImageFixtures.write(ImageFixtures.png(), named: "o.png", in: outside)

    for (name, target) in [("out.png", "outside/o.png"), ("gone.png", "outside/none.png")] {
      try FileManager.default.createSymbolicLink(
        atPath: folder.appendingPathComponent(name).path,
        withDestinationPath: root.appendingPathComponent(target).path)
    }

    scope = try ReadScope(directories: [folder.path])
    addTeardownBlock { [root] in try? FileManager.default.removeItem(at: root!) }
  }

  private func scopedFolder() throws -> OpenedFolder {
    guard case .success(let opened) = ScopedOpen.open(path: folder.path, in: scope),
      let wrapped = OpenedFolder(scoped: opened, path: folder.path)
    else { throw XCTSkip("the folder did not open") }

    return wrapped
  }

  /// Catches a listing that stats a link's target. A scoped folder counts every link by its name,
  /// a live one and a dangling one alike, so the count says nothing about a target outside the
  /// scope. An ordinary folder still skips a dangling link.
  func testAScopedListingNeverFollowsALink() throws {
    let types = SupportedImageTypes()
    let scoped = try scopedFolder()

    let names = try scoped.list(supporting: types, sort: .name).get().map(\.name)

    XCTAssertEqual(names, ["a.png", "gone.png", "out.png"])

    guard case .success(.folder(let plain)) = SourceOpener.open(path: folder.path) else {
      return XCTFail("the folder did not open")
    }

    let plainNames = try plain.list(supporting: types, sort: .name).get().map(\.name)

    XCTAssertEqual(plainNames, ["a.png", "out.png"], "the dangling link is not an image")
  }

  /// Catches a member that opens outside the scope through a link. A member in the scope opens and
  /// names its real path. A link out, and a dangling link out, are both refused.
  func testAScopedFolderOpensItsMembersOnlyInsideTheScope() throws {
    let scoped = try scopedFolder()

    guard case .success(let inside) = scoped.openFile(named: "a.png") else {
      return XCTFail("a member in the scope did not open")
    }

    XCTAssertEqual(inside.realPath, folder.appendingPathComponent("a.png").path)

    for name in ["out.png", "gone.png", "../outside/o.png"] {
      guard case .failure = scoped.openFile(named: name) else {
        return XCTFail("\(name) opened")
      }
    }
  }

  /// Catches a shown file whose folder is read for siblings outside the scope. A file in the scope
  /// loads with its folder scoped, and the load names the file's real path.
  func testALoadedFileGetsAScopedFolder() throws {
    guard
      case .success(let opened) = ScopedOpen.open(
        path: folder.appendingPathComponent("a.png").path, in: scope)
    else { throw XCTSkip("the file did not open") }

    let loaded = try SourceLoader.loadBlocking(
      opened: opened, scope: scope, realPath: folder.appendingPathComponent("a.png").path,
      sort: .name, types: SupportedImageTypes()
    ).get()

    XCTAssertEqual(loaded.kind, .file)
    XCTAssertEqual(loaded.image?.realPath, folder.appendingPathComponent("a.png").path)
    XCTAssertEqual(loaded.folder?.isScoped, true)
    XCTAssertFalse(loaded.folderNotListed)
  }
}
