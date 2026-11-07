import XCTest

@testable import BrowserModel

final class UnsentInputTests: XCTestCase {
  private let a = String(repeating: "a", count: 32)
  private let b = String(repeating: "b", count: 32)

  /// Catches a body the native side would take that the script never sends: a bare boolean, a
  /// number that looks like one, extra keys, or a frame token of the wrong shape.
  func testOnlyAFrameTokenAndARealBooleanAreAccepted() {
    XCTAssertEqual(
      UnsentInputReport(body: ["frame": a, "unsent": true] as [String: Any]),
      UnsentInputReport(frame: a, unsent: true))
    XCTAssertEqual(
      UnsentInputReport(body: ["frame": a, "unsent": false] as [String: Any])?.unsent, false)

    let rejected: [Any] = [
      true, 1, "true", NSNull(), [String: Any](), [a, true],
      ["frame": a, "unsent": 1] as [String: Any],
      ["frame": a, "unsent": 0] as [String: Any],
      ["frame": a, "unsent": "true"] as [String: Any],
      ["frame": a] as [String: Any],
      ["frame": a, "unsent": true, "extra": 1] as [String: Any],
      ["frame": 5, "unsent": true] as [String: Any],
      ["frame": "short", "unsent": true] as [String: Any],
      ["frame": String(repeating: "A", count: 32), "unsent": true] as [String: Any],
      ["frame": String(repeating: "a", count: 33), "unsent": true] as [String: Any],
      ["frame": String(repeating: "g", count: 32), "unsent": true] as [String: Any],
    ]

    for body in rejected {
      XCTAssertNil(UnsentInputReport(body: body), "\(body)")
    }
  }

  /// Catches one frame clearing another's mark, and a mark that outlives every frame's report.
  func testAFrameClearsOnlyItsOwnMark() {
    var ledger = UnsentInputLedger()

    XCTAssertTrue(ledger.apply(UnsentInputReport(frame: a, unsent: true)))
    XCTAssertFalse(ledger.apply(UnsentInputReport(frame: b, unsent: true)))
    XCTAssertFalse(ledger.apply(UnsentInputReport(frame: b, unsent: false)))
    XCTAssertTrue(ledger.isMarked)
    XCTAssertTrue(ledger.apply(UnsentInputReport(frame: a, unsent: false)))
    XCTAssertFalse(ledger.isMarked)
    XCTAssertFalse(ledger.apply(UnsentInputReport(frame: a, unsent: false)))
  }

  func testClearForgetsEveryFrame() {
    var ledger = UnsentInputLedger()

    ledger.apply(UnsentInputReport(frame: a, unsent: true))
    ledger.apply(UnsentInputReport(frame: b, unsent: true))

    XCTAssertTrue(ledger.clear())
    XCTAssertFalse(ledger.isMarked)
    XCTAssertFalse(ledger.clear())
  }

  /// Catches a flood of distinct tokens growing the ledger without bound, and a frame beyond the
  /// bound that is dirty and then reads as clean. Past the bound the ledger remembers only that
  /// something was dropped, and the tab stays marked until a load, so the failure is a question the
  /// user can answer, never a lost draft.
  func testPastTheBoundTheTabStaysMarkedUntilALoad() {
    var ledger = UnsentInputLedger()
    let total = UnsentInputLedger.maximumFrames + 1

    for index in 0..<total {
      ledger.apply(UnsentInputReport(frame: String(format: "%032x", index), unsent: true))
    }

    for index in 0..<UnsentInputLedger.maximumFrames {
      ledger.apply(UnsentInputReport(frame: String(format: "%032x", index), unsent: false))
    }

    XCTAssertTrue(ledger.isMarked, "the frame over the bound was dirty and reads as clean")

    ledger.apply(UnsentInputReport(frame: String(format: "%032x", total - 1), unsent: false))

    XCTAssertTrue(ledger.isMarked, "a clear for a frame the ledger never held cannot unmark")
    XCTAssertTrue(ledger.clear())
    XCTAssertFalse(ledger.isMarked)
  }
}
