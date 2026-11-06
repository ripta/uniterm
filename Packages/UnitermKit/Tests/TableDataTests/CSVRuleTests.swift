import XCTest

@testable import TableData

/// The documented rule that picks a CSV file's encoding, delimiter, and header. Each test names the
/// wrong pick it would catch.
final class CSVRuleTests: XCTestCase {
  private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

  // MARK: Encoding

  /// Catches a BOM that is read as data, or a UTF-16 file that falls through to the code page.
  func testAByteOrderMarkWinsAndIsSkipped() {
    XCTAssertEqual(CSVRule.encoding(of: [0xEF, 0xBB, 0xBF, 0x61], isWholeFile: true).bom, 3)
    XCTAssertEqual(
      CSVRule.encoding(of: [0xEF, 0xBB, 0xBF, 0x61], isWholeFile: true).encoding, .utf8)

    let little = CSVRule.encoding(of: [0xFF, 0xFE, 0x61, 0x00], isWholeFile: true)
    XCTAssertEqual(little.encoding, .utf16LittleEndian)
    XCTAssertEqual(little.bom, 2)

    let big = CSVRule.encoding(of: [0xFE, 0xFF, 0x00, 0x61], isWholeFile: true)
    XCTAssertEqual(big.encoding, .utf16BigEndian)
  }

  /// Catches a valid UTF-8 file that reads as Windows-1252, and a Windows-1252 file that reads as
  /// UTF-8. The accented bytes decide: C3 A9 is one UTF-8 letter, and a lone E9 is not UTF-8.
  func testValidUTF8IsUTF8AndAnythingElseIsWindows1252() {
    XCTAssertEqual(
      CSVRule.encoding(of: bytes("caf\u{E9},1\n"), isWholeFile: true).encoding, .utf8)
    XCTAssertEqual(
      CSVRule.encoding(of: [0x63, 0x61, 0x66, 0xE9, 0x2C, 0x31], isWholeFile: true).encoding,
      .windows1252)
  }

  /// Catches a sample that cuts a multi-byte letter and sends a UTF-8 file to the code page. The
  /// same cut bytes are invalid when they are the whole file.
  func testASampleThatCutsACharacterStillCountsAsUTF8() {
    let cut: [UInt8] = [0x61, 0xC3]

    XCTAssertEqual(CSVRule.encoding(of: cut, isWholeFile: false).encoding, .utf8)
    XCTAssertEqual(CSVRule.encoding(of: cut, isWholeFile: true).encoding, .windows1252)
  }

  // MARK: Delimiter

  /// Catches a sniffer that cannot tell the four delimiters apart, or one that counts a delimiter
  /// inside quotes.
  func testTheDelimiterIsTheMostConsistentCandidate() {
    XCTAssertEqual(
      CSVRule.delimiter(in: bytes("a,b,c\n1,2,3\n"), fileExtension: "csv"), UInt8(ascii: ","))
    XCTAssertEqual(
      CSVRule.delimiter(in: bytes("a;b;c\n1;2;3\n"), fileExtension: "csv"), UInt8(ascii: ";"))
    XCTAssertEqual(CSVRule.delimiter(in: bytes("a\tb\n1\t2\n"), fileExtension: "csv"), 0x09)
    XCTAssertEqual(
      CSVRule.delimiter(in: bytes("a|b\n1|2\n"), fileExtension: "csv"), UInt8(ascii: "|"))

    let quoted = bytes("\"a,b,c\";x\n\"d,e,f\";y\n")
    XCTAssertEqual(CSVRule.delimiter(in: quoted, fileExtension: "csv"), UInt8(ascii: ";"))
  }

  /// Catches a tie that goes anywhere but comma, and a one-column file that picks a delimiter it
  /// does not use. Both candidates split every row in two.
  func testATieAndASingleColumnGoToComma() {
    XCTAssertEqual(
      CSVRule.delimiter(in: bytes("a,b;c\n1,2;3\n"), fileExtension: "csv"), UInt8(ascii: ","))
    XCTAssertEqual(
      CSVRule.delimiter(in: bytes("a\nb\nc\n"), fileExtension: "csv"), UInt8(ascii: ","))
  }

  /// Catches a `.tsv` file with commas in its text that sniffs as comma.
  func testATabSeparatedNameMeansTab() {
    let text = bytes("a,b,c\td\n1,2,3\t4\n")

    XCTAssertEqual(CSVRule.delimiter(in: text, fileExtension: "tsv"), 0x09)
    XCTAssertEqual(CSVRule.delimiter(in: text, fileExtension: "TAB"), 0x09)
  }

  // MARK: Header

  /// Catches a numeric first row that is taken as a header, and `nan` or `inf` text that is taken
  /// for a number and loses the header.
  func testTheFirstRowIsAHeaderUnlessACellIsANumber() {
    XCTAssertTrue(CSVRule.isHeader(["name", "city"]))
    XCTAssertTrue(CSVRule.isHeader(["nan", "inf", "Infinity"]))
    XCTAssertTrue(CSVRule.isHeader(["", "b"]))
    XCTAssertFalse(CSVRule.isHeader(["a", "1"]))
    XCTAssertFalse(CSVRule.isHeader(["-2.5e3", "b"]))
    XCTAssertFalse(CSVRule.isHeader([" 7 ", "b"]))
    XCTAssertTrue(CSVRule.isHeader(["1.2.3", "2024-01-01", "12abc", "e5", "1e"]))
  }
}
