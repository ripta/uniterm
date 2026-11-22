import XCTest

@testable import StatusKit

final class StatusTextTests: XCTestCase {
  /// Catches a line or paragraph separator that survives cleaning and lets one status segment
  /// draw on two lines. Each expected value is written by hand: the separator becomes one space.
  /// It cannot prove how the bar draws the text, only that no separator reaches it.
  func testLineAndParagraphSeparatorsBecomeSpaces() {
    XCTAssertEqual(StatusText.bounded("a\u{2028}b", maximumBytes: 64), "a b")
    XCTAssertEqual(StatusText.bounded("a\u{2029}b", maximumBytes: 64), "a b")
    XCTAssertEqual(StatusText.bounded("\u{2028}a\u{2029}", maximumBytes: 64), "a")
  }
}
