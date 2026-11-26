import XCTest

@testable import TableData

/// The rule that marks a column as numeric, read through the loader the way a pane reads a file.
final class NumericColumnsTests: XCTestCase {
  private func numeric(_ loaded: Loaded) -> [String] {
    let found = NumericColumns.find(in: loaded.snapshot) ?? IndexSet()

    return found.map { loaded.snapshot.columns[$0].title }
  }

  /// Catches a CSV column of numbers that reads as text, and one with a word in it that reads as
  /// numbers. Empty cells do not count either way, and a column with nothing but empty cells is
  /// not numeric.
  func testACSVColumnIsNumericWhenEveryFilledCellIsANumber() throws {
    let scratch = try Scratch(self)
    let file = try scratch.write(
      "a.csv", "id,price,code,blank,name\n1,3.5,7,,ann\n2,,x9,,bob\n30,-1e3,8,,cy\n")

    XCTAssertEqual(numeric(loadFile(file)), ["id", "price"])
  }

  /// Catches a JSON string of digits that counts as a number, and a null that makes a column of
  /// numbers read as text. The kind decides, as it does for the sort.
  func testAJSONColumnFollowsItsCellKinds() throws {
    let scratch = try Scratch(self)
    let file = try scratch.write(
      "a.json",
      #"[{"n":1,"s":"12","m":2,"b":true},{"n":null,"s":"13","m":"x","b":false},{"s":"1"}]"#)

    XCTAssertEqual(numeric(loadFile(file)), ["n"])
  }

  /// Catches a spreadsheet date, which the reader shows as text, that counts as a number. Plain
  /// numbers do, and a date column does not.
  func testASpreadsheetDateIsNotANumber() throws {
    let scratch = try Scratch(self)
    let rows =
      Workbook.row(
        1,
        #"<c r="A1" t="inlineStr"><is><t>amount</t></is></c><c r="B1" t="inlineStr"><is><t>day</t></is></c>"#
      )
      + Workbook.row(2, #"<c r="A2"><v>4.25</v></c><c r="B2" s="1"><v>45000</v></c>"#)
    let file = try scratch.write(
      "a.xlsx", Workbook.bytes(sheets: [SheetSpec("S", rows)], styles: [0, 14]))

    XCTAssertEqual(numeric(loadFile(file)), ["amount"])
  }

  /// Catches a scan that keeps going after a cancel.
  func testACancelledScanReturnsNothing() throws {
    let scratch = try Scratch(self)
    var text = "n\n"
    for index in 0..<1_000 { text += "\(index)\n" }

    let loaded = loadFile(try scratch.write("a.csv", text))

    XCTAssertNil(NumericColumns.find(in: loaded.snapshot, isCancelled: { true }))
  }
}
