import XCTest

@testable import TableData

/// The CSV dialect, row by row. The expected rows are written by hand from the dialect's rules.
final class CSVParserTests: XCTestCase {
  private func parse(_ text: String, chunk: Int? = nil, delimiter: UInt8 = UInt8(ascii: ","))
    -> [[String]]
  {
    parse(Array(text.utf8), chunk: chunk, delimiter: delimiter)
  }

  private func parse(_ bytes: [UInt8], chunk: Int? = nil, delimiter: UInt8 = UInt8(ascii: ","))
    -> [[String]]
  {
    var parser = CSVParser(delimiter: delimiter)
    var rows: [[String]] = []

    let sink: CSVParser.Sink = { row, ends in
      var start = 0
      var cells: [String] = []

      for end in ends {
        cells.append(String(decoding: row[start..<Int(end)], as: UTF8.self))
        start = Int(end)
      }

      rows.append(cells)
      return true
    }

    let size = chunk ?? max(bytes.count, 1)
    var offset = 0

    while offset < bytes.count {
      parser.feed(bytes[offset..<min(offset + size, bytes.count)], sink: sink)
      offset += size
    }

    parser.finish(sink: sink)
    return rows
  }

  /// Catches the plain dialect: fields split on commas, rows on each newline kind, and a final row
  /// with no newline.
  func testRowsEndAtLFCRAndCRLFAndTheLastRowNeedsNoNewline() {
    XCTAssertEqual(
      parse("a,b\r\nc,d\ne,f\rg,h"), [["a", "b"], ["c", "d"], ["e", "f"], ["g", "h"]])
  }

  /// Catches a quoted field that splits at its comma or newline, a doubled quote that stays doubled,
  /// and an empty quoted field that vanishes.
  func testQuotedFieldsKeepDelimitersNewlinesAndDoubledQuotes() {
    XCTAssertEqual(
      parse("\"a,b\",\"line1\nline2\",\"say \"\"hi\"\"\",\"\"\nx,y,z,w\n"),
      [["a,b", "line1\nline2", "say \"hi\"", ""], ["x", "y", "z", "w"]])
  }

  /// Catches blank lines that become empty rows, and a trailing delimiter that loses its empty
  /// cell. A blank line between CRLF rows must not eat the next row.
  func testBlankLinesAreSkippedAndATrailingDelimiterMakesAnEmptyCell() {
    XCTAssertEqual(parse("a,b\r\n\r\nc,\n\n"), [["a", "b"], ["c", ""]])
  }

  /// Catches a parser that rejects real files: a quote in the middle of a bare field is text, text
  /// after a closing quote joins the field, and a quote still open at the end ends there.
  func testMalformedQuotingIsReadLeniently() {
    XCTAssertEqual(parse("5\" pipe,b\n"), [["5\" pipe", "b"]])
    XCTAssertEqual(parse("\"ab\"cd,e\n"), [["abcd", "e"]])
    XCTAssertEqual(parse("a,\"never closed\nstill"), [["a", "never closed\nstill"]])
  }

  /// Catches a parser that depends on where a read ends. Every split of the input, down to one byte
  /// at a time, gives the rows of the whole input. CR LF split across chunks is the sharp case.
  func testTheChunkBoundaryNeverChangesTheRows() {
    let text = "h1,h2\r\n\"a\"\"b\",\"c\r\nd\"\r\n\r\n,x,\n1,2"
    let whole = parse(text)

    for chunk in 1...text.utf8.count {
      XCTAssertEqual(parse(text, chunk: chunk), whole, "chunk \(chunk)")
    }
  }

  /// Catches the other delimiters being ignored.
  func testTheDelimiterIsConfigurable() {
    XCTAssertEqual(
      parse("a;b\n1;\"2;3\"\n", delimiter: UInt8(ascii: ";")), [["a", "b"], ["1", "2;3"]])
  }

  /// Catches an unbounded cell. A cell cuts at the cell cap and the row is counted as truncated, so a
  /// hostile file cannot hold gigabytes in one field.
  func testAnOversizedCellIsCutAndCounted() {
    var parser = CSVParser(delimiter: UInt8(ascii: ","))
    var lengths: [Int] = []

    let big = [UInt8](repeating: 0x78, count: CSVParser.maxCellBytes + 500)
    parser.feed(big[...]) { _, _ in true }
    parser.feed(Array(",y\n".utf8)[...]) { row, ends in
      lengths = [Int(ends[0]), row.count]
      return true
    }

    XCTAssertEqual(lengths, [CSVParser.maxCellBytes, CSVParser.maxCellBytes + 1])
    XCTAssertEqual(parser.truncatedRows, 1)
  }

  /// Catches a row with endless cells. Cells past the cap are dropped and counted.
  func testARowWithTooManyCellsIsCut() {
    var parser = CSVParser(delimiter: UInt8(ascii: ","))
    var cells = 0

    let row = [UInt8](repeating: UInt8(ascii: ","), count: CSVParser.maxCells + 10) + [0x0A]
    parser.feed(row[...]) { _, ends in
      cells = ends.count
      return true
    }

    XCTAssertEqual(cells, CSVParser.maxCells)
    XCTAssertEqual(parser.truncatedRows, 1)
  }

  /// Catches a sink that cannot stop the parse.
  func testTheSinkCanStopTheParse() {
    var parser = CSVParser(delimiter: UInt8(ascii: ","))
    var rows = 0

    parser.feed(Array("a\nb\nc\n".utf8)[...]) { _, _ in
      rows += 1
      return false
    }

    XCTAssertEqual(rows, 1)
    XCTAssertTrue(parser.stopped)
  }
}
