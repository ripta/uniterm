import XCTest

@testable import BrowserModel

@MainActor
final class HSTSStoreClearTests: XCTestCase {
  /// Catches a second clear that reports success while the file still holds hosts. The file sits
  /// under a regular file, so no write can succeed. The first clear fails. The second has an empty
  /// list in memory and must still fail, since the file was never emptied.
  func testASecondClearAfterAFailedWriteStillSaysTheFileHoldsHosts() throws {
    let blocker = FileManager.default.temporaryDirectory
      .appending(path: "uniterm-hsts-block-\(UUID().uuidString)")

    try Data().write(to: blocker)
    defer { try? FileManager.default.removeItem(at: blocker) }

    let store = HSTSStore(file: blocker.appending(path: "hsts.json"))

    store.record(host: "example.com", header: "max-age=3600")

    XCTAssertEqual(store.count, 1)
    XCTAssertFalse(store.removeAll())
    XCTAssertEqual(store.count, 0)
    XCTAssertFalse(store.removeAll(), "the second clear reported a file that was never emptied")
  }

  /// Catches a clear that fails for a store whose file writes fine, or one with nothing to clear.
  func testAClearThatWritesTheFileSucceedsAndSoDoesAnEmptyOne() throws {
    let file = FileManager.default.temporaryDirectory
      .appending(path: "uniterm-hsts-\(UUID().uuidString)", directoryHint: .isDirectory)
      .appending(path: "hsts.json")
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

    let store = HSTSStore(file: file)

    XCTAssertTrue(store.removeAll())

    store.record(host: "example.com", header: "max-age=3600")

    XCTAssertTrue(store.removeAll())
    XCTAssertTrue(store.removeAll())
    XCTAssertEqual(HSTSStore(file: file).count, 0)
  }
}
