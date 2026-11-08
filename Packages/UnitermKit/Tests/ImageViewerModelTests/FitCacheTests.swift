import XCTest

@testable import ImageViewerModel

final class FitCacheTests: XCTestCase {
  private func entry(_ name: String, _ value: Int, modified: Double? = 1) -> FitCache<Int>.Entry {
    FitCache<Int>.Entry(name: name, modified: modified, value: value)
  }

  /// Catches a cache that holds more than one image on each side, or that forgets to hand back the
  /// older entry so its memory is returned. Storing a newer entry returns the one it replaced.
  func testStoringANewerEntryReturnsTheOlderOne() {
    var cache = FitCache<Int>()

    XCTAssertNil(cache.keepPrevious(entry("a", 1)))
    XCTAssertEqual(cache.keepPrevious(entry("b", 2))?.name, "a")
    XCTAssertNil(cache.keepPrefetched(entry("c", 3)))
    XCTAssertEqual(cache.keepPrefetched(entry("d", 4))?.value, 3)
  }

  /// Catches a step to a held image decoding it again, and a replaced file matching its old decode.
  /// An entry matches by name and modification time, and taking it removes it.
  func testTakeMatchesByNameAndModificationTimeAndRemovesTheEntry() {
    var cache = FitCache<Int>()

    _ = cache.keepPrefetched(entry("next", 1, modified: 5))
    _ = cache.keepPrevious(entry("back", 2, modified: 6))

    XCTAssertNil(cache.take(name: "next", modified: 99), "the file changed on disk")
    XCTAssertEqual(cache.take(name: "next", modified: 5)?.value, 1)
    XCTAssertNil(cache.take(name: "next", modified: 5))
    XCTAssertEqual(cache.take(name: "back", modified: 6)?.value, 2)
    XCTAssertTrue(cache.isEmpty)
  }

  /// Catches a sort or a reload leaving a prefetch for the wrong neighbor. Dropping the prefetched
  /// slot empties only that slot.
  func testDroppingThePrefetchedSlotKeepsThePreviousOne() {
    var cache = FitCache<Int>()

    _ = cache.keepPrefetched(entry("next", 1))
    _ = cache.keepPrevious(entry("back", 2))

    XCTAssertEqual(cache.dropPrefetched()?.name, "next")
    XCTAssertNil(cache.prefetched)
    XCTAssertTrue(cache.holds(name: "back", modified: 1))
    XCTAssertEqual(cache.removeAll().count, 1)
  }
}
