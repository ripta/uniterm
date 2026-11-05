import XCTest

@testable import TableData

/// The loader through its production entry point, on real files. Expected tables are written by
/// hand from the CSV rule.
final class TableLoaderTests: XCTestCase {
  /// Catches a loader that returns the wrong cells or columns for a plain file: the header row
  /// names the columns and is not a data row, and a short row has empty cells.
  func testAPlainFileLoadsAsAHeaderAndRows() throws {
    let scratch = try Scratch(self)
    let file = try scratch.write("a.csv", "name,qty\nwidget,3\ngadget\n")

    let loaded = loadFile(file)

    XCTAssertEqual(loaded.end, .completed)
    XCTAssertEqual(loaded.titles, ["name", "qty"])
    XCTAssertEqual(loaded.rows, [["widget", "3"], ["gadget", ""]])
  }

  /// Catches two same-named headers that share an identity, so a restored sort lands on the wrong
  /// column. An empty header cell is named by its position, and so is a column past the header.
  func testColumnsKeepSeparateIdentities() throws {
    let scratch = try Scratch(self)
    let file = try scratch.write("a.csv", "amount,,amount\n1x,2x,3x,4x\n")

    let columns = loadFile(file).snapshot.columns

    XCTAssertEqual(
      columns.map(\.identity),
      [
        .named("amount", occurrence: 0), .positional(1), .named("amount", occurrence: 1),
        .positional(3),
      ])
    XCTAssertEqual(columns.map(\.title), ["amount", "Column 2", "amount", "Column 4"])
  }

  /// Catches a numeric first row that is eaten as a header. The file has no header, so the first
  /// row is data and every column is named by position.
  func testAFirstRowWithANumberIsDataAndColumnsAreNamedByPosition() throws {
    let scratch = try Scratch(self)
    let file = try scratch.write("a.csv", "x,1\ny,2\n")

    let loaded = loadFile(file)

    XCTAssertEqual(loaded.rows, [["x", "1"], ["y", "2"]])
    XCTAssertEqual(loaded.snapshot.columns.map(\.identity), [.positional(0), .positional(1)])
  }

  /// Catches an encoding pick that garbles text: UTF-8 with a BOM, UTF-16 in both byte orders, and
  /// Windows-1252 each give the same table. Expected text is written as scalars so the file
  /// bytes are independent of the code under test.
  func testEveryEncodingGivesTheSameTable() throws {
    let scratch = try Scratch(self)
    let text = "name,note\ncaf\u{E9},\u{20AC}5 \u{1F600}\n"
    let expected = [["caf\u{E9}", "\u{20AC}5 \u{1F600}"]]

    let utf8Bom = try scratch.write("bom.csv", [0xEF, 0xBB, 0xBF] + Array(text.utf8))
    let little = try scratch.write(
      "le.csv", [0xFF, 0xFE] + text.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
    let big = try scratch.write(
      "be.csv", [0xFE, 0xFF] + text.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] })

    for file in [utf8Bom, little, big] {
      let loaded = loadFile(file)
      XCTAssertEqual(loaded.titles, ["name", "note"], file.lastPathComponent)
      XCTAssertEqual(loaded.rows, expected, file.lastPathComponent)
    }

    let cp1252 = try scratch.write(
      "cp.csv", Array("name,note\ncaf".utf8) + [0xE9, 0x2C, 0x80, 0x35, 0x0A])
    XCTAssertEqual(loadFile(cp1252).rows, [["caf\u{E9}", "\u{20AC}5"]])
  }

  /// Catches a loader that blocks on or reads from a FIFO, a folder, or a missing path. Each ends
  /// with a message that names what it is, and none reads a byte.
  func testOnlyRegularFilesLoad() throws {
    let scratch = try Scratch(self)
    let fifo = scratch.url.appendingPathComponent("pipe.csv").path
    XCTAssertEqual(mkfifo(fifo, 0o600), 0)

    let folder = scratch.url.appendingPathComponent("folder.csv")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

    let pipe = loadFile(URL(fileURLWithPath: fifo))
    XCTAssertEqual(pipe.end, .failed(.notARegularFile(path: fifo, kind: "a pipe")))
    XCTAssertEqual(pipe.progress.bytesRead, 0)

    XCTAssertEqual(
      loadFile(folder).end, .failed(.notARegularFile(path: folder.path, kind: "a folder")))

    let missing = scratch.url.appendingPathComponent("gone.csv")
    XCTAssertEqual(loadFile(missing).end, .failed(.missing(path: missing.path)))
  }

  /// Catches a protected file that reports "missing" or "corrupt" in place of a permission message.
  func testAFileThatCannotBeReadReportsPermission() throws {
    let scratch = try Scratch(self)
    let file = try scratch.write("locked.csv", "a,b\n1,2\n")
    XCTAssertEqual(chmod(file.path, 0), 0)

    XCTAssertEqual(loadFile(file).end, .failed(.permissionDenied(path: file.path)))
  }

  /// Catches a declared type that the viewer cannot read yet and shows an empty table or crashes.
  /// A spreadsheet says the format is not supported yet, and a format that never loads says so.
  func testAFormatTheViewerCannotReadShowsAMessage() throws {
    let scratch = try Scratch(self)
    let xlsx = try scratch.write("a.xlsx", "x")
    let xls = try scratch.write("a.xls", "x")

    let xlsxEnd = loadFile(xlsx)
    XCTAssertEqual(
      xlsxEnd.end,
      .failed(.unsupportedFormat(path: xlsx.path, description: "a spreadsheet", comingLater: true)))
    XCTAssertEqual(xlsxEnd.snapshot.rowCount, 0)
    XCTAssertTrue(
      try XCTUnwrap(
        TableLoadError.unsupportedFormat(
          path: xlsx.path, description: "a spreadsheet", comingLater: true
        ).errorDescription
      ).contains("not supported yet"))

    XCTAssertEqual(
      loadFile(xls).end,
      .failed(.unsupportedFormat(path: xls.path, description: "a .xls file", comingLater: false)))
  }

  /// Catches a budget that is not honored. A file bigger than the budget loads its first rows
  /// and stops, never a partial page, and the rows it kept are the file's first rows in order.
  func testAFileLargerThanTheBudgetKeepsItsFirstRows() throws {
    let scratch = try Scratch(self)
    var text = "id,value\n"
    for index in 0..<2000 { text += "\(index),row-\(index)\n" }

    let file = try scratch.write("big.csv", text)
    let budget = TableBudget(limit: 4_000, floor: 0)

    let loaded = loadFile(file, budget: budget, pageTarget: 1_000)

    XCTAssertEqual(loaded.end, .stoppedAtBudget)
    XCTAssertGreaterThan(loaded.snapshot.rowCount, 0)
    XCTAssertLessThan(loaded.snapshot.rowCount, 2000)
    XCTAssertLessThanOrEqual(loaded.snapshot.pages.reduce(0) { $0 + $1.cost }, 4_000)

    for row in 0..<loaded.snapshot.rowCount {
      XCTAssertEqual(loaded.snapshot.text(row: row, column: 0), "\(row)")
    }
  }

  /// Catches a pane that opens while others hold the whole budget and shows nothing. The floor
  /// still loads rows for it.
  func testALeaseOverTheBudgetStillGetsItsFloor() throws {
    let scratch = try Scratch(self)
    let file = try scratch.write("a.csv", "id,v\n1,a\n2,b\n")
    let budget = TableBudget(limit: 100, floor: 10_000)
    let hog = budget.makeLease()
    XCTAssertEqual(hog.reserve(10_000), .granted)
    XCTAssertEqual(hog.reserve(1), .overBudget)

    let loaded = loadFile(file, budget: budget)

    XCTAssertEqual(loaded.end, .completed)
    XCTAssertEqual(loaded.rows.count, 2)
  }

  /// Catches a memory warning that does not stop a load. The load running at the warning ends with
  /// the rows it holds, and a load that starts afterward is not affected. The warning arrives
  /// between two reads, from the cancellation check.
  func testAMemoryWarningStopsTheLoadRunningAtThatMoment() throws {
    let scratch = try Scratch(self)
    var text = "id,v\n"
    for index in 0..<80_000 { text += "\(index),row-\(index)\n" }

    let file = try scratch.write("a.csv", text)
    let budget = TableBudget(limit: 1 << 30, floor: 1 << 20)
    var checks = 0

    let stopped = loadFile(
      file, budget: budget, pageTarget: 2_000,
      isCancelled: {
        checks += 1
        if checks == 1 { budget.memoryPressureWarning() }
        return false
      })

    XCTAssertEqual(stopped.end, .stoppedLowMemory)
    XCTAssertGreaterThan(stopped.snapshot.rowCount, 0)
    XCTAssertLessThan(stopped.snapshot.rowCount, 80_000)

    XCTAssertEqual(loadFile(file, budget: budget, pageTarget: 2_000).end, .completed)
  }

  /// Catches a load that ignores cancellation: it ends as cancelled at the next chunk.
  func testACancelledLoadEndsAsCancelled() throws {
    let scratch = try Scratch(self)
    var text = "id,v\n"
    for index in 0..<100_000 { text += "\(index),row-\(index)\n" }

    let file = try scratch.write("a.csv", text)

    XCTAssertEqual(loadFile(file, isCancelled: { true }).end, .cancelled)
  }

  /// Catches rows that arrive under a size cap with no notice. Oversized cells are counted.
  func testOversizedCellsAreReportedInTheProgress() throws {
    let scratch = try Scratch(self)
    let file = try scratch.write(
      "a.csv", "a,b\n" + String(repeating: "x", count: CSVParser.maxCellBytes + 10) + ",y\nz,w\n")

    let loaded = loadFile(file)

    XCTAssertEqual(loaded.progress.truncatedRows, 1)
    XCTAssertEqual(loaded.snapshot.cell(row: 0, column: 0).count, CSVParser.maxCellBytes)
    XCTAssertEqual(loaded.rows[1], ["z", "w"])
  }

  /// Catches an empty file that fails or shows a stale table, and a header with no rows.
  func testEmptyFilesAndHeaderOnlyFiles() throws {
    let scratch = try Scratch(self)

    let empty = loadFile(try scratch.write("empty.csv", ""))
    XCTAssertEqual(empty.end, .completed)
    XCTAssertTrue(empty.snapshot.columns.isEmpty)

    let header = loadFile(try scratch.write("header.csv", "a,b\n"))
    XCTAssertEqual(header.titles, ["a", "b"])
    XCTAssertEqual(header.snapshot.rowCount, 0)
  }

  /// Catches a page lookup that lands in the wrong page. Many small pages must return every row
  /// at its own index, including the first cell of each page.
  func testRowsAcrossManyPagesKeepTheirIndex() throws {
    let scratch = try Scratch(self)
    var text = "n\n"
    for index in 0..<500 { text += "v\(index)\n" }

    let loaded = loadFile(try scratch.write("a.csv", text), pageTarget: 64)

    XCTAssertEqual(loaded.snapshot.rowCount, 500)

    for row in stride(from: 0, to: 500, by: 7) {
      XCTAssertEqual(loaded.snapshot.text(row: row, column: 0), "v\(row)")
    }

    XCTAssertEqual(loaded.snapshot.text(row: 499, column: 0), "v499")
    XCTAssertEqual(loaded.snapshot.text(row: 500, column: 0), "")
  }

  /// Catches a load that goes on after its lease was released, the window in which a cancelled
  /// loader would take budget back. The load ends without rows and the budget stays empty.
  func testALoadOnAReleasedLeaseEndsWithNoRows() throws {
    let scratch = try Scratch(self)
    let file = try scratch.write("a.csv", "id,v\n1,a\n2,b\n")
    let budget = TableBudget(limit: 1 << 30, floor: 1 << 20)
    let lease = budget.makeLease()
    lease.release()
    let log = EventLog()

    TableLoader.loadBlocking(.file(file), lease: lease, isCancelled: { false }, emit: log.add)

    guard case .finished(let snapshot, let end, _)? = log.events.last else {
      return XCTFail("no finished event")
    }

    XCTAssertEqual(end, .cancelled)
    XCTAssertEqual(snapshot.rowCount, 0)
    XCTAssertEqual(budget.used, 0)
  }

  /// Catches a page that takes more memory than the budget charged for it. The charge counts
  /// the bytes, so the arrays must not keep the spare capacity that growing them left behind.
  func testSealedPagesHoldNoSpareCapacity() throws {
    let scratch = try Scratch(self)
    var text = "id,v\n"
    for index in 0..<7_000 { text += "\(index),value \(index)\n" }

    let snapshot = loadFile(try scratch.write("a.csv", text)).snapshot

    XCTAssertFalse(snapshot.pages.isEmpty)

    // The allocator rounds a large block up to a 16 KiB page. Growing the arrays left far more.
    let slack = 16 * 1024

    for page in snapshot.pages {
      XCTAssertLessThanOrEqual(page.bytes.capacity - page.bytes.count, slack)
      XCTAssertLessThanOrEqual(4 * (page.cellEnds.capacity - page.cellEnds.count), slack)
      XCTAssertLessThanOrEqual(4 * (page.rowFirstCell.capacity - page.rowFirstCell.count), slack)
    }
  }

  /// Catches a sample wider than the rule says. The rule reads the first 64 KiB, and the loader
  /// reads 256 KiB at a time. UTF-8 text in the first 64 KiB makes a UTF-8 file, whatever bytes
  /// follow. The lone E9 byte at about 100 KiB shows as U+FFFD and must not turn the file into
  /// Windows-1252, which would garble the accented letter in the first row.
  func testTheEncodingIsPickedFromTheFirst64KiBOnly() throws {
    let scratch = try Scratch(self)
    var bytes = Array("a,b\ncaf\u{E9},1\n".utf8)
    for _ in 0..<25_000 { bytes += Array("x,1\n".utf8) }
    bytes += [0x79, 0xE9, 0x2C, 0x32, 0x0A]

    XCTAssertGreaterThan(bytes.count, 100_000)

    let loaded = loadFile(try scratch.write("a.csv", bytes))

    XCTAssertEqual(loaded.snapshot.text(row: 0, column: 0), "caf\u{E9}")
    XCTAssertEqual(loaded.snapshot.text(row: loaded.snapshot.rowCount - 1, column: 0), "y\u{FFFD}")
  }

  /// Catches a format check that hides the real reason a file cannot open. A stored path that is
  /// gone or protected says so, whatever its extension.
  func testAMissingOrProtectedFileIsReportedBeforeItsFormat() throws {
    let scratch = try Scratch(self)
    let gone = scratch.url.appendingPathComponent("notes.txt")
    XCTAssertEqual(loadFile(gone).end, .failed(.missing(path: gone.path)))

    let locked = try scratch.write("locked.json", "[]")
    XCTAssertEqual(chmod(locked.path, 0), 0)
    XCTAssertEqual(loadFile(locked).end, .failed(.permissionDenied(path: locked.path)))
  }
}
