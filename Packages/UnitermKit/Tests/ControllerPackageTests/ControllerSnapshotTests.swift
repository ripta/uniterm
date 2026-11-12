import ControllerTestSupport
import CryptoKit
import Darwin
import Foundation
import XCTest

@testable import ControllerPackage

/// A run's private copy of a package: what it refuses, and that nothing done to the source before,
/// during, or after the copy changes what it holds.
final class ControllerSnapshotTests: XCTestCase {
  private var runs: URL!

  override func setUpWithError() throws {
    runs = try ControllerFixtures.temporaryFolder().appendingPathComponent("runs")
  }

  override func tearDown() {
    ControllerSnapshot.removeStale(in: runs)
  }

  private func snapshot(_ package: URL, afterCopying: ((String) -> Void)? = nil) throws
    -> ControllerSnapshot
  {
    try ControllerSnapshot.create(from: package.path, in: runs, afterCopying: afterCopying)
  }

  private func assertRefused(
    _ package: URL, saying fragment: String, file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertThrowsError(try snapshot(package), file: file, line: line) { error in
      XCTAssertTrue("\(error)".contains(fragment), "\(error)", file: file, line: line)
    }

    let left = (try? FileManager.default.contentsOfDirectory(atPath: runs.path)) ?? []

    XCTAssertEqual(left, [], "a refused snapshot left a folder", file: file, line: line)
  }

  private func mode(_ url: URL) -> mode_t {
    var info = stat()

    _ = lstat(url.path, &info)

    return info.st_mode & 0o777
  }

  /// Catches a snapshot that holds more or less than the listed files, one whose files or folders
  /// stay writable, or one whose identity differs from the shared fixture's.
  func testASnapshotHoldsExactlyTheListedFilesReadOnly() throws {
    let made = try snapshot(ControllerFixtures.package("janet-hello"))

    XCTAssertEqual(made.controller.identity.version, ControllerFixtures.Hello.version)
    XCTAssertEqual(
      made.controller.identity.keyFingerprint, ControllerFixtures.Hello.keyFingerprint)

    let held = try FileManager.default.subpathsOfDirectory(atPath: made.directory.path).sorted()

    XCTAssertEqual(
      held, ["controller.json", "controller.sig", "lib", "lib/greet.janet", "main.janet"])
    XCTAssertEqual(mode(made.directory), 0o500, "the snapshot folder")
    XCTAssertEqual(mode(made.directory.appendingPathComponent("lib")), 0o500, "its lib folder")
    XCTAssertEqual(mode(made.directory.appendingPathComponent("main.janet")), 0o400)
    XCTAssertEqual(mode(runs), 0o700)

    let loaded = try ControllerSnapshot.load(
      at: made.directory.path, version: made.controller.descriptor.versionDigest)

    XCTAssertEqual(
      loaded.files.mapValues { Data(SHA256.hash(data: $0)).hex }, ControllerFixtures.Hello.files)

    made.remove()

    XCTAssertFalse(FileManager.default.fileExists(atPath: made.directory.path))
  }

  /// Catches a package whose listed file is a link, whose folder is a link, or that holds a FIFO,
  /// a missing file, or a file the descriptor does not list.
  func testLinksSpecialFilesMissingAndUnlistedFilesFailClosed() throws {
    let main = Data("(print 1)\n".utf8)
    let builder = ControllerPackageBuilder(files: ["main.janet": main, "lib/a.janet": main])

    let linkedFile = try builder.write()
    let outside = linkedFile.deletingLastPathComponent().appendingPathComponent("outside.janet")

    try main.write(to: outside)
    try FileManager.default.removeItem(at: linkedFile.appendingPathComponent("lib/a.janet"))
    try FileManager.default.createSymbolicLink(
      at: linkedFile.appendingPathComponent("lib/a.janet"), withDestinationURL: outside)
    assertRefused(linkedFile, saying: "lib/a.janet is a link")

    let linkedFolder = try builder.write()
    let elsewhere = linkedFolder.deletingLastPathComponent().appendingPathComponent("elsewhere")

    try FileManager.default.moveItem(
      at: linkedFolder.appendingPathComponent("lib"), to: elsewhere)
    try FileManager.default.createSymbolicLink(
      at: linkedFolder.appendingPathComponent("lib"), withDestinationURL: elsewhere)
    assertRefused(linkedFolder, saying: "lib is a link")

    let fifo = try builder.write()

    XCTAssertEqual(mkfifo(fifo.appendingPathComponent("pipe").path, 0o600), 0)
    assertRefused(fifo, saying: "pipe is not a plain file or a folder")

    let missing = try builder.write()

    try FileManager.default.removeItem(at: missing.appendingPathComponent("lib/a.janet"))
    assertRefused(missing, saying: "lib/a.janet is listed in controller.json and is missing")

    var extra = builder

    extra.unlisted = ["lib/b.janet": main]
    assertRefused(try extra.write(), saying: "lib/b.janet is in the package and not listed")

    let changed = try builder.write()

    try Data("(print 2)\n".utf8).write(to: changed.appendingPathComponent("lib/a.janet"))
    assertRefused(changed, saying: "lib/a.janet does not match the digest")
  }

  /// Catches a copy that takes source bytes that changed during the copy. A file replaced after it
  /// was copied leaves the snapshot's verified copy alone. A file replaced before its turn fails
  /// its digest, and no snapshot is made.
  func testReplacingTheSourceDuringTheCopyCannotSubstituteCode() throws {
    let original = Data("(print :original)\n".utf8)
    let substitute = Data("(print :substitute)\n".utf8)
    let builder = ControllerPackageBuilder(files: ["a.janet": original, "main.janet": original])

    let early = try builder.write()
    let made = try snapshot(early) { path in
      if path == "a.janet" { try? substitute.write(to: early.appendingPathComponent("a.janet")) }
    }

    XCTAssertEqual(try Data(contentsOf: made.directory.appendingPathComponent("a.janet")), original)

    let late = try builder.write()

    XCTAssertThrowsError(
      try snapshot(late) { path in
        if path == "a.janet" {
          try? substitute.write(to: late.appendingPathComponent("main.janet"))
        }
      }
    ) { error in
      XCTAssertTrue("\(error)".contains("main.janet does not match"), "\(error)")
    }

    let linked = try builder.write()
    let outside = linked.deletingLastPathComponent().appendingPathComponent("outside.janet")

    try original.write(to: outside)
    XCTAssertThrowsError(
      try snapshot(linked) { path in
        guard path == "a.janet" else { return }

        let target = linked.appendingPathComponent("main.janet")

        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
      }
    ) { error in
      XCTAssertTrue("\(error)".contains("main.janet passes through a link"), "\(error)")
    }
  }

  /// Catches a snapshot that follows its source. Editing a file, replacing the whole package folder
  /// at the original path, or removing it, after the snapshot is made, leaves the snapshot and
  /// what the loader reads from it as they were.
  func testUpdatingTheOriginalPathAfterTheSnapshotLeavesItUnchanged() throws {
    let source = try ControllerFixtures.copy("janet-hello")
    let made = try snapshot(source)
    let version = made.controller.descriptor.versionDigest

    try Data("(print :edited)\n".utf8).write(to: source.appendingPathComponent("main.janet"))

    let replacement = try ControllerPackageBuilder(
      files: ["main.janet": Data("(print :replaced)\n".utf8)]
    ).write()

    try FileManager.default.removeItem(at: source)
    try FileManager.default.moveItem(at: replacement, to: source)

    let loaded = try ControllerSnapshot.load(at: made.directory.path, version: version)

    XCTAssertEqual(
      loaded.files.mapValues { Data(SHA256.hash(data: $0)).hex }, ControllerFixtures.Hello.files)
    XCTAssertEqual(loaded.descriptor.id, ControllerFixtures.Hello.id)
  }

  /// Catches a loader that runs a snapshot whose descriptor is not the version the app verified,
  /// or whose file changed after the check.
  func testTheLoaderRefusesAnotherVersionOrAChangedSnapshotFile() throws {
    let made = try snapshot(ControllerFixtures.package("janet-hello"))

    XCTAssertThrowsError(
      try ControllerSnapshot.load(at: made.directory.path, version: Data(count: 32)))

    let main = made.directory.appendingPathComponent("main.janet")

    XCTAssertEqual(chmod(made.directory.path, 0o700), 0)
    XCTAssertEqual(chmod(main.path, 0o600), 0)
    try Data("(print :tampered)\n".utf8).write(to: main)

    XCTAssertThrowsError(
      try ControllerSnapshot.load(
        at: made.directory.path, version: made.controller.descriptor.versionDigest)
    ) { error in
      XCTAssertTrue("\(error)".contains("no longer matches"), "\(error)")
    }
  }

  /// Catches the stale cleanup leaving a run folder behind, including a read-only one.
  func testStaleRunFoldersAreRemovedAtLaunch() throws {
    let made = try snapshot(ControllerFixtures.package("janet-hello"))

    ControllerSnapshot.removeStale(in: runs)

    XCTAssertFalse(FileManager.default.fileExists(atPath: made.directory.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: runs.path))
  }
}
