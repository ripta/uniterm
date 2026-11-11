import Darwin
import Foundation
import XCTest

@testable import LayoutKit

final class LayoutStoreTests: XCTestCase {
  private func makeStore(
    _ directory: URL, policy: LayoutStorePolicy = .standard
  ) -> LayoutStore {
    LayoutStore(directory: directory, policy: policy)
  }

  private let sample = SavedLayout(windows: [window(tree: pane(1))])

  private func names(in directory: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
  }

  // MARK: Saving

  func testASavedLayoutIsReadBackOnTheNextLaunch() throws {
    let directory = try makeScratch(self)
    let first = makeStore(directory)
    XCTAssertTrue(try first.acquire())
    _ = try first.beginLaunch()
    try first.save(sample)
    first.release()

    let second = makeStore(directory)
    XCTAssertTrue(try second.acquire())

    guard case .restored(let layout) = try second.beginLaunch() else {
      return XCTFail("expected the saved layout")
    }

    XCTAssertEqual(layout.windows.count, 1)
    XCTAssertEqual(layout.windows[0].tree.paneIDs.map(\.rawValue), [1])
  }

  /// Catches a file or temp file that other users could read. The umask is cleared, so a mode that
  /// came from the default 0666 and not from the store would show. The temp file becomes the
  /// layout by rename, so its mode is the layout's mode.
  func testTheFileAndTheDirectoryArePrivateEvenWithAnOpenUmask() throws {
    let directory = try makeScratch(self).appendingPathComponent("uniterm")
    let previous = umask(0)
    defer { umask(previous) }

    let store = makeStore(directory)
    XCTAssertTrue(try store.acquire())
    _ = try store.beginLaunch()
    try store.save(sample)

    XCTAssertEqual(try permissions(of: store.layoutURL), 0o600)
    XCTAssertEqual(try permissions(of: store.markerURL), 0o600)
    XCTAssertEqual(try permissions(of: directory), 0o700)
  }

  /// Catches a write that leaves its temp file behind, and a stale one that survives a launch.
  func testNoTempFileSurvivesASaveOrALaunch() throws {
    let directory = try makeScratch(self)
    let stale = directory.appendingPathComponent("layout.json.tmp-1")
    try Data("old".utf8).write(to: stale)

    let store = makeStore(directory)
    XCTAssertTrue(try store.acquire())
    _ = try store.beginLaunch()
    try store.save(sample)

    XCTAssertTrue(
      names(in: directory).allSatisfy { !$0.contains(".tmp-") }, "\(names(in: directory))")
  }

  /// Catches a failed write that replaces the good file. A directory in the temp file's place
  /// makes the write fail, and the old bytes must remain.
  func testAFailedSaveLeavesTheOldFileInPlace() throws {
    let directory = try makeScratch(self)
    let store = makeStore(directory)
    XCTAssertTrue(try store.acquire())
    _ = try store.beginLaunch()
    try store.save(sample)

    let before = try Data(contentsOf: store.layoutURL)

    chmod(directory.path, 0o500)
    defer { chmod(directory.path, 0o700) }

    XCTAssertThrowsError(try store.save(SavedLayout(windows: [])))
    XCTAssertEqual(try Data(contentsOf: store.layoutURL), before)
  }

  // MARK: Single writer

  /// Catches a second instance that writes. The lock is per open file, so two stores in one
  /// process behave like two processes.
  func testASecondInstanceNeverGetsTheLock() throws {
    let directory = try makeScratch(self)
    let first = makeStore(directory)
    let second = makeStore(directory)

    XCTAssertTrue(try first.acquire())
    _ = try first.beginLaunch()
    try first.save(sample)

    let before = try Data(contentsOf: first.layoutURL)

    XCTAssertFalse(try second.acquire())
    XCTAssertFalse(second.isWriter)
    XCTAssertEqual(try Data(contentsOf: first.layoutURL), before)

    first.release()
    XCTAssertTrue(try second.acquire(), "the lock is free once the first instance lets go")
  }

  /// Catches a trap on the quit path. An instance without the lock gets an error it can report,
  /// and the layout file is not touched.
  func testAnInstanceWithoutTheLockThrowsInsteadOfTrapping() throws {
    let directory = try makeScratch(self)
    let owner = makeStore(directory)
    let other = makeStore(directory)
    XCTAssertTrue(try owner.acquire())
    _ = try owner.beginLaunch()
    try owner.save(sample)

    let before = try Data(contentsOf: owner.layoutURL)

    XCTAssertFalse(try other.acquire())

    XCTAssertThrowsError(try other.save(SavedLayout(windows: []))) {
      guard case .notWriter? = $0 as? LayoutStoreError else {
        return XCTFail("expected notWriter, got \($0)")
      }
    }

    XCTAssertThrowsError(try other.beginLaunch()) {
      guard case .notWriter? = $0 as? LayoutStoreError else {
        return XCTFail("expected notWriter, got \($0)")
      }
    }

    XCTAssertEqual(try Data(contentsOf: owner.layoutURL), before)
  }

  // MARK: Recovery

  private func plant(_ text: String, in directory: URL) throws {
    try Data(text.utf8).write(to: directory.appendingPathComponent("layout.json"))
  }

  func testAnUnreadableFileIsKeptAsideAndAFreshLayoutStarts() throws {
    let directory = try makeScratch(self)
    try plant("not json at all", in: directory)

    let store = makeStore(directory)
    XCTAssertTrue(try store.acquire())

    guard case .fresh(let notice) = try store.beginLaunch() else {
      return XCTFail("expected a fresh layout")
    }

    XCTAssertNotNil(notice)
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.layoutURL.path))
    XCTAssertEqual(store.keptAsideFiles.count, 1)
    XCTAssertEqual(
      try String(contentsOf: store.keptAsideFiles[0], encoding: .utf8), "not json at all")
  }

  func testANewerFileIsKeptAside() throws {
    let directory = try makeScratch(self)
    try plant(#"{"version":\#(LayoutCodec.currentVersion + 1),"windows":[]}"#, in: directory)

    let store = makeStore(directory)
    XCTAssertTrue(try store.acquire())

    guard case .fresh = try store.beginLaunch() else { return XCTFail("expected fresh") }

    XCTAssertEqual(store.keptAsideFiles.count, 1)
  }

  /// Catches a keep-aside that overwrites an earlier one, or one that never prunes. Seven files
  /// are set aside with a limit of five. The newest five stay, each with its own bytes.
  func testRepeatedKeepAsidesNeverOverwriteAndAreBounded() throws {
    let directory = try makeScratch(self)
    let store = makeStore(
      directory, policy: LayoutStorePolicy(crashedLaunchBound: 3, keepAsideLimit: 5))
    XCTAssertTrue(try store.acquire())

    for number in 1...7 {
      try plant("bad \(number)", in: directory)
      _ = try store.beginLaunch()
      store.finishLaunch()
    }

    let kept = try store.keptAsideFiles.map { try String(contentsOf: $0, encoding: .utf8) }

    XCTAssertEqual(kept, ["bad 3", "bad 4", "bad 5", "bad 6", "bad 7"])
  }

  // MARK: Crash loop

  /// Catches a guard that never fires and one that fires too soon. Three launches begin and never
  /// finish. The third still restores. The fourth moves the file aside.
  func testALaunchThatKeepsCrashingEndsInAFreshLayoutWithTheOldFileKept() throws {
    let directory = try makeScratch(self)
    let first = makeStore(directory)
    XCTAssertTrue(try first.acquire())
    _ = try first.beginLaunch()
    try first.save(sample)
    first.finishLaunch()
    first.release()

    for attempt in 1...3 {
      let store = makeStore(directory)
      XCTAssertTrue(try store.acquire())

      guard case .restored = try store.beginLaunch() else {
        return XCTFail("launch \(attempt) should still restore")
      }

      store.release()
    }

    let fourth = makeStore(directory)
    XCTAssertTrue(try fourth.acquire())

    guard case .fresh(let notice) = try fourth.beginLaunch() else {
      return XCTFail("the fourth launch should start fresh")
    }

    XCTAssertNotNil(notice)
    XCTAssertEqual(fourth.keptAsideFiles.count, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fourth.layoutURL.path))
  }

  /// Catches a launch that fails to read the layout yet leaves its marker behind. Three such
  /// launches would count as crashes and move a valid layout aside. Here the layout path is a
  /// directory, so the read throws.
  func testALaunchThatThrowsLeavesNoMarker() throws {
    let directory = try makeScratch(self)
    let store = makeStore(directory)
    XCTAssertTrue(try store.acquire())
    try FileManager.default.createDirectory(at: store.layoutURL, withIntermediateDirectories: false)

    XCTAssertThrowsError(try store.beginLaunch())
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.markerURL.path))
  }

  /// A finished launch clears the count, so crashes that are far apart never add up.
  func testAFinishedLaunchResetsTheCrashCount() throws {
    let directory = try makeScratch(self)
    let seed = makeStore(directory)
    XCTAssertTrue(try seed.acquire())
    _ = try seed.beginLaunch()
    try seed.save(sample)
    seed.finishLaunch()
    seed.release()

    for _ in 1...10 {
      let store = makeStore(directory)
      XCTAssertTrue(try store.acquire())

      guard case .restored = try store.beginLaunch() else { return XCTFail("expected restore") }

      store.finishLaunch()
      store.release()
    }
  }

  func testTheCrashBoundComesFromThePolicy() throws {
    let directory = try makeScratch(self)
    let policy = LayoutStorePolicy(crashedLaunchBound: 1, keepAsideLimit: 5)

    let seed = makeStore(directory, policy: policy)
    XCTAssertTrue(try seed.acquire())
    _ = try seed.beginLaunch()
    try seed.save(sample)
    seed.release()

    let second = makeStore(directory, policy: policy)
    XCTAssertTrue(try second.acquire())

    guard case .fresh = try second.beginLaunch() else { return XCTFail("one crash is the bound") }
  }

  func testACopyKeptAsideLeavesTheLayoutInPlace() throws {
    let directory = try makeScratch(self)
    let store = makeStore(directory)
    XCTAssertTrue(try store.acquire())
    _ = try store.beginLaunch()
    try store.save(sample)

    let kept = try store.keepCopyAside()

    XCTAssertNotNil(kept)
    XCTAssertTrue(FileManager.default.fileExists(atPath: store.layoutURL.path))
    XCTAssertEqual(try Data(contentsOf: kept!), try Data(contentsOf: store.layoutURL))
    XCTAssertEqual(try permissions(of: kept!), 0o600)
  }
}
