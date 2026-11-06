import XCTest

@testable import BrowserModel

final class AddressDisplayTests: XCTestCase {
  /// Catches an address that reaches a pane or a notice with a bidirectional override that
  /// reorders the text around it, or a line break that splits the sentence. A stored address is
  /// text a layout file chose.
  func testBidirectionalControlsAndLineBreaksNeverReachTheDisplay() {
    let shown = AddressDisplay.bounded("file:///a\u{202E}txt.exe\nb\u{2066}c\u{200F}d")

    XCTAssertFalse(shown.unicodeScalars.contains { (0x202A...0x202E).contains($0.value) })
    XCTAssertFalse(shown.unicodeScalars.contains { (0x2066...0x2069).contains($0.value) })
    XCTAssertFalse(shown.unicodeScalars.contains("\u{200F}"))
    XCTAssertFalse(shown.contains("\n"))
    XCTAssertEqual(shown, "file:///atxt.exe bcd")
  }

  /// Catches a bound that counts characters and not bytes. A very long run of combining marks is one
  /// character, so a character cut leaves it whole.
  func testALongRunOfCombiningMarksIsCutByBytes() {
    let shown = AddressDisplay.bounded("ftp://x/a" + String(repeating: "\u{0301}", count: 5000))

    XCTAssertLessThanOrEqual(shown.utf8.count, AddressDisplay.maximumBytes + 3)
    XCTAssertTrue(shown.hasSuffix("\u{2026}"))
  }

  func testAShortAddressIsUnchangedAndALongOneIsCutByCharacters() {
    XCTAssertEqual(AddressDisplay.bounded("https://example.com/a"), "https://example.com/a")

    let long = AddressDisplay.bounded("https://example.com/" + String(repeating: "a", count: 300))

    XCTAssertEqual(long.count, AddressDisplay.maximumCharacters + 1)
    XCTAssertTrue(long.hasSuffix("\u{2026}"))
  }
}
