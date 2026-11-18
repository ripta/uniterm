import Foundation
import XCTest

@testable import SourceAccess

/// The lexical rules of a read scope: containment, coverage, the protected places, and what a
/// caller may be told about a pane's source. No test here touches the disk.
final class ReadScopeTests: XCTestCase {
  private let protected = ProtectedLocations(home: "/Users/pat")

  private func scope(_ directories: String...) throws -> ReadScope {
    try ReadScope(directories: directories)
  }

  /// Catches a scope that accepts a path it could not hold apart, such as a relative one or one
  /// that climbs, and so would let a spelling stand for two folders.
  func testOnlyPlainAbsoluteDirectoriesFormAScope() throws {
    for bad in ["relative", "/a/../b", "/a/./b", "/a//b", "/a/b/", "", "/a\u{0}b"] {
      XCTAssertThrowsError(try ReadScope(directories: [bad]), bad.debugDescription)
    }

    XCTAssertThrowsError(try ReadScope(directories: []))
    XCTAssertThrowsError(try ReadScope(directories: ["/a", "/a"]))
    XCTAssertEqual(try ReadScope(directories: ["/b", "/a"]).directories, ["/a", "/b"])
  }

  /// Catches the protected list drifting from the places the design names. The one list is this
  /// type's, so a test that fails here is the place to change it on purpose.
  func testTheProtectedListNamesEveryPlaceTheDesignNames() {
    let labels = Set(protected.entries.map(\.label))

    XCTAssertEqual(
      labels,
      [
        "Documents", "Desktop", "Downloads", "iCloud Drive", "other apps' containers",
        "removable and network volumes", "the Photos library",
      ])

    let paths = Set(protected.entries.compactMap(\.path))

    for path in [
      "/Users/pat/Documents", "/Users/pat/Desktop", "/Users/pat/Downloads",
      "/Users/pat/Library/Mobile Documents", "/Users/pat/Library/Containers",
      "/Users/pat/Library/Group Containers", "/Volumes", "/Network",
    ] {
      XCTAssertTrue(paths.contains(path), path)
    }
  }

  /// Catches a scope of the home folder reaching Documents, which would lend uniterm's own macOS
  /// grant to a controller with none.
  func testAScopeLeavesOutTheProtectedPlacesItContains() throws {
    let home = try scope("/Users/pat")

    XCTAssertTrue(home.contains(path: "/Users/pat/notes/a.txt", protected: protected))
    XCTAssertTrue(home.contains(path: "/Users/pat", protected: protected))

    for left in [
      "/Users/pat/Documents", "/Users/pat/Documents/x", "/Users/pat/Desktop/a",
      "/Users/pat/Downloads/a.zip", "/Users/pat/Library/Mobile Documents/com~apple~CloudDocs/a",
      "/Users/pat/Library/Containers/com.example/Data/a",
      "/Users/pat/Library/Group Containers/g/a", "/Users/pat/Pictures/Photos Library.photoslibrary",
      "/Users/pat/Pictures/Photos Library.photoslibrary/database/a",
      "/Users/pat/Pictures/Other.PhotosLibrary/a",
    ] {
      XCTAssertFalse(home.contains(path: left, protected: protected), left)
    }

    XCTAssertFalse(
      try scope("/").contains(path: "/Volumes/Backup/a", protected: protected),
      "a scope of the root still leaves out other volumes")
  }

  /// Catches a scope that names a protected place failing to cover it, which would make it
  /// impossible to grant Documents on purpose.
  func testAScopeThatNamesAProtectedPlaceCoversIt() throws {
    let named = try scope("/Users/pat", "/Users/pat/Documents")

    XCTAssertTrue(named.contains(path: "/Users/pat/Documents/x", protected: protected))
    XCTAssertFalse(named.contains(path: "/Users/pat/Desktop/x", protected: protected))

    let inside = try scope("/Users/pat/Documents/project")

    XCTAssertTrue(inside.contains(path: "/Users/pat/Documents/project/a", protected: protected))
    XCTAssertFalse(inside.contains(path: "/Users/pat/Documents/other", protected: protected))
  }

  /// Catches a spelling that widens or narrows a scope: the same folder written with another
  /// Unicode normalization, and with another case on a volume that ignores case.
  func testPathsCompareByNormalizationAndByTheVolumesCase() throws {
    let accented = try scope("/Users/pat/caf\u{E9}")

    XCTAssertTrue(
      accented.contains(path: "/Users/pat/cafe\u{301}/a", protected: protected),
      "NFD spelling of an NFC scope")

    XCTAssertFalse(
      accented.contains(path: "/Users/pat/Caf\u{E9}/a", using: .exact, protected: protected),
      "an exact volume tells a different case apart")

    XCTAssertTrue(
      accented.contains(
        path: "/Users/pat/CAFE\u{301}/a", using: PathComparison(isCaseSensitive: false),
        protected: protected),
      "a volume that ignores case does not")

    XCTAssertFalse(
      try scope("/Users/pat").contains(
        path: "/Users/pat/documents/x", using: PathComparison(isCaseSensitive: false),
        protected: protected),
      "a lower-case spelling of Documents is still Documents on such a volume")
  }

  /// Catches coverage compared on raw paths: a request for Documents under an approved home
  /// folder must be broader, so it asks.
  func testCoverageComparesEffectiveScopes() throws {
    let home = try scope("/Users/pat")

    XCTAssertTrue(try scope("/Users/pat/notes").isCovered(by: home, protected: protected))
    XCTAssertTrue(try scope("/Users/pat").isCovered(by: home, protected: protected))
    XCTAssertTrue(
      try scope("/Users/pat/notes", "/Users/pat/src").isCovered(by: home, protected: protected))

    XCTAssertFalse(
      try scope("/Users/pat/Documents/x").isCovered(by: home, protected: protected))
    XCTAssertFalse(try scope("/Users/pat/Documents").isCovered(by: home, protected: protected))
    XCTAssertFalse(
      try scope("/Users/pat/Pictures/L.photoslibrary").isCovered(by: home, protected: protected))
    XCTAssertFalse(try scope("/Users").isCovered(by: home, protected: protected))
    XCTAssertFalse(
      try scope("/Users/pat/notes", "/Users/pat/Downloads").isCovered(
        by: home, protected: protected))

    XCTAssertTrue(
      try scope("/Users/pat/Documents/x").isCovered(
        by: try scope("/Users/pat", "/Users/pat/Documents"), protected: protected))
    XCTAssertTrue(
      try scope("/Users/pat/Documents/x").isCovered(
        by: try scope("/Users/pat/Documents/x"), protected: protected))
    XCTAssertFalse(
      try scope("/Users/pat/caf\u{E9}").isCovered(
        by: try scope("/Users/pat/Caf\u{E9}"), protected: protected),
      "an exact comparison only ever asks again")
    XCTAssertTrue(
      try scope("/Users/pat/caf\u{E9}").isCovered(
        by: try scope("/Users/pat/cafe\u{301}"), protected: protected))
  }

  /// Catches the approval panel missing a protected place: it must name each one a scope lies in
  /// or names, and each one a scope leaves out.
  func testLabelsNameWhatAScopeLiesInNamesAndLeavesOut() throws {
    let nested = try scope("/Users/pat/Documents/project").protectedLabels(protected: protected)

    XCTAssertEqual(nested.lyingIn, ["Documents"])

    let named = try scope("/Users/pat/Downloads").protectedLabels(protected: protected)

    XCTAssertEqual(named.lyingIn, ["Downloads"])

    let wide = try scope("/Users/pat").protectedLabels(protected: protected)

    XCTAssertEqual(wide.lyingIn, [])
    XCTAssertEqual(
      Set(wide.leftOut),
      [
        "Documents", "Desktop", "Downloads", "iCloud Drive", "other apps' containers",
        "the Photos library",
      ])

    let volumes = try scope("/Volumes/Backup").protectedLabels(protected: protected)

    XCTAssertEqual(volumes.lyingIn, ["removable and network volumes"])
  }

  /// Catches a pane's source shown to a caller that cannot read it, and content the caller sent
  /// itself hidden from the caller.
  func testAPaneSourceOutsideTheScopeIsNotShown() throws {
    let access = ReadAccess(
      scope: try scope("/Users/pat/notes"), controllerSentRoot: "/Users/pat/sent/42-1")

    XCTAssertTrue(access.mayShow(source: nil, protected: protected))
    XCTAssertTrue(access.mayShow(source: "/Users/pat/notes/a.md", protected: protected))
    XCTAssertTrue(access.mayShow(source: "/Users/pat/sent/42-1/x.md", protected: protected))
    XCTAssertFalse(access.mayShow(source: "/Users/pat/other/a.md", protected: protected))
    XCTAssertFalse(access.mayShow(source: "relative.md", protected: protected))

    XCTAssertFalse(
      ReadAccess.none.mayShow(source: "/Users/pat/notes/a.md", protected: protected),
      "a caller with no power sees no user file")
    XCTAssertTrue(ReadAccess.none.mayShow(source: nil, protected: protected))
  }

  /// Catches a protected place matched with a simpler case rule than the volume's. APFS folds with
  /// Unicode case folding, so U+017F (long s) spells the same name as an S, and U+212A (Kelvin
  /// sign) as a K. A path so spelled must still be inside the protected place, whatever the
  /// volume of the scope says, since hiding more is always safe.
  func testProtectedPlacesMatchByUnicodeCaseFolding() throws {
    let home = try scope("/Users/pat")

    for spelled in [
      "/Users/pat/De\u{17F}ktop/x", "/Users/pat/DESKTOP/x", "/Users/pat/desktop/x",
      "/Users/pat/Des\u{212A}top/x", "/Users/pat/Downloads/x".uppercased(),
      "/Users/pat/Pictures/Photos Library.PHOTOSLIBRARY/x",
      "/Users/pat/Pictures/L.photo\u{17F}library/x",
    ] {
      for comparison in [PathComparison.exact, PathComparison(isCaseSensitive: false)] {
        XCTAssertFalse(
          home.contains(path: spelled, using: comparison, protected: protected), spelled)
      }
    }

    XCTAssertFalse(
      ReadAccess(scope: home).mayShow(source: "/Users/pat/documents/x", protected: protected))
    XCTAssertTrue(
      PathComparison(isCaseSensitive: false).areEqual("De\u{17F}ktop", "Desktop"),
      "a case-insensitive volume folds long s")
    XCTAssertTrue(PathComparison(isCaseSensitive: false).areEqual("\u{212A}", "k"))
  }

  /// Catches a scope directory that is a link into a protected place going unnamed. The labels of
  /// the resolved directory join the written ones.
  func testResolvedDirectoriesNameTheProtectedPlacesALinkLeadsInto() throws {
    let linked = try scope("/Users/pat/notes")

    XCTAssertEqual(linked.protectedLabels(protected: protected).lyingIn, [])

    let seen = linked.protectedLabels(
      resolved: ["/Users/pat/notes": "/Users/pat/Documents/notes"], protected: protected)

    XCTAssertEqual(seen.lyingIn, ["Documents"])
  }

  /// Catches the resolution reading nothing, or keeping a directory that is not there.
  func testResolvedDirectoriesFollowLinksAndSkipMissingOnes() throws {
    let base = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("uniterm-resolve-\(UUID().uuidString)", isDirectory: true)
    let real = base.appendingPathComponent("real")

    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createSymbolicLink(
      atPath: base.appendingPathComponent("link").path, withDestinationPath: real.path)

    let link = base.appendingPathComponent("link").path
    let missing = base.appendingPathComponent("missing").path
    let resolved = try ReadScope(directories: [link, missing]).resolvedDirectories()

    XCTAssertEqual(resolved[missing], nil)
    XCTAssertEqual(
      resolved[link],
      try XCTUnwrap(realpath(real.path, nil)).withMemoryRebound(to: CChar.self, capacity: 1024) {
        String(cString: $0)
      })
  }
}
