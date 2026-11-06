import Foundation
import TableTestSupport
import XCTest

@testable import TableData

/// Loads `.xlsx` files that the tests build in code. These prove the workbook reader's contract:
/// what a cell shows, where it lands, and how the reader refuses the files it must not trust.
final class XLSXLoaderTests: XCTestCase {
  private func load(
    _ bytes: [UInt8], name: String = "book.xlsx", sheet: String? = nil,
    limits: SpreadsheetLimits = .standard,
    budget: TableBudget = TableBudget(limit: 1 << 30, floor: 1 << 20),
    pageTarget: Int = TableLoader.defaultPageTarget, isCancelled: @escaping () -> Bool = { false },
    afterLease: (TableBudget) -> Void = { _ in }
  ) throws -> Loaded {
    let scratch = try Scratch(self)
    let file = try scratch.write(name, bytes)

    let log = EventLog()
    let lease = budget.makeLease()
    afterLease(budget)

    TableLoader.loadBlocking(
      .file(file, sheet: sheet), lease: lease, pageTarget: pageTarget,
      limits: limits, isCancelled: isCancelled, emit: log.add)

    guard case .finished(let snapshot, let end, let progress)? = log.events.last else {
      fatalError("a load must end with a finished event")
    }

    return Loaded(snapshot: snapshot, end: end, progress: progress, events: log.events)
  }

  private func failure(_ loaded: Loaded) -> TableLoadError? {
    if case .failed(let error) = loaded.end { return error }

    return nil
  }

  private func cell(_ reference: String, _ value: String, type: String? = nil, style: Int? = nil)
    -> String
  {
    let t = type.map { #" t="\#($0)""# } ?? ""
    let s = style.map { #" s="\#($0)""# } ?? ""

    return #"<c r="\#(reference)"\#(s)\#(t)><v>\#(value)</v></c>"#
  }

  // MARK: Cells

  /// Catches a reader that drops rich runs, includes phonetic hints, or leaves `_x` escapes raw.
  func testSharedInlineAndRichStringsShowTheirText() throws {
    let strings =
      #"<sst><si><t>Name</t></si><si><r><t>Hel</t></r><r><t>lo</t></r><rPh sb="0" eb="1"><t>PHONETIC</t></rPh></si>"#
      + #"<si><t xml:space="preserve"> a_x0041_b </t></si></sst>"#

    let rows =
      Workbook.row(1, cell("A1", "0", type: "s") + cell("B1", "0", type: "s"))
      + Workbook.row(
        2,
        cell("A2", "1", type: "s")
          + #"<c r="B2" t="inlineStr"><is><r><t>in</t></r><r><t>line</t></r></is></c>"#)
      + Workbook.row(3, cell("A3", "2", type: "s") + cell("B3", "x", type: "str"))

    let loaded = try load(
      Workbook.bytes(sheets: [SheetSpec("S", rows)], stringsXML: strings))

    XCTAssertEqual(loaded.end, .completed)
    XCTAssertEqual(loaded.rows, [["Hello", "inline"], [" aAb ", "x"]])
  }

  /// Catches cells that shift left when the row skips some, and cells written out of order.
  func testSparseCellsLandInTheColumnTheirReferenceNames() throws {
    let rows =
      Workbook.row(
        1,
        cell("A1", "H", type: "str") + cell("B1", "I", type: "str") + cell("C1", "J", type: "str"))
      + Workbook.row(2, cell("A2", "1") + cell("C2", "3"))
      + Workbook.row(3, cell("C3", "30") + cell("A3", "10"))
      + Workbook.row(4, "<c><v>7</v></c><c><v>8</v></c>")
      + Workbook.row(5, cell("AA5", "99"))

    let loaded = try load(Workbook.bytes(sheets: [SheetSpec("S", rows)]))

    XCTAssertEqual(loaded.snapshot.columns.count, 27)
    XCTAssertEqual(loaded.text(0, "H"), "1")
    XCTAssertEqual(loaded.text(0, "I"), "")
    XCTAssertEqual(loaded.text(0, "J"), "3")
    XCTAssertEqual(loaded.text(1, "H"), "10")
    XCTAssertEqual(loaded.text(1, "J"), "30")
    XCTAssertEqual(loaded.text(2, "H"), "7")
    XCTAssertEqual(loaded.text(2, "I"), "8")
    XCTAssertEqual(loaded.snapshot.text(row: 3, column: 26), "99")
    XCTAssertEqual(loaded.kind(0, "I"), .missing)
    XCTAssertEqual(loaded.kind(0, "H"), .number)
  }

  /// Catches a formula that shows blank or zero when Excel stored no result.
  func testFormulaWithNoCachedValueShowsAsNotComputed() throws {
    let rows =
      Workbook.row(1, cell("A1", "N", type: "str") + cell("B1", "M", type: "str"))
      + Workbook.row(
        2,
        #"<c r="A2"><f>1+1</f></c>"# + #"<c r="B2"><f>1+1</f><v>2</v></c>"#)
      + Workbook.row(
        3, #"<c r="A3" t="str"><f>""</f><v></v></c>"# + #"<c r="B3"><f>A1</f><v></v></c>"#)

    let loaded = try load(Workbook.bytes(sheets: [SheetSpec("S", rows)]))

    XCTAssertEqual(loaded.kind(0, "N"), .notComputed)
    XCTAssertEqual(loaded.text(0, "N"), "")
    XCTAssertEqual(loaded.kind(0, "M"), .number)
    XCTAssertEqual(loaded.text(0, "M"), "2")
    XCTAssertEqual(loaded.kind(1, "M"), .notComputed)
    XCTAssertEqual(loaded.kind(1, "N"), .missing)
  }

  /// Catches booleans and errors losing their meaning.
  func testBooleansAndErrorsKeepTheirKinds() throws {
    let rows =
      Workbook.row(1, cell("A1", "B", type: "str") + cell("B1", "E", type: "str"))
      + Workbook.row(2, cell("A2", "1", type: "b") + cell("B2", "#DIV/0!", type: "e"))
      + Workbook.row(3, cell("A3", "0", type: "b"))

    let loaded = try load(Workbook.bytes(sheets: [SheetSpec("S", rows)]))

    XCTAssertEqual(loaded.rows, [["true", "#DIV/0!"], ["false", ""]])
    XCTAssertEqual(loaded.kind(0, "B"), .bool)
    XCTAssertEqual(loaded.kind(0, "E"), .string)
  }

  // MARK: Dates

  /// Catches a date system that is off by a day, including Excel's invented 1900-02-29.
  func testDatesShowUnderTheNineteenHundredSystemIncludingSerialSixty() throws {
    let serials = ["0", "1", "59", "60", "61", "36526", "44927", "44927.75", "0.5", "-1"]
    let rows =
      Workbook.row(1, cell("A1", "when", type: "str"))
      + serials.enumerated().map {
        Workbook.row($0.offset + 2, cell("A\($0.offset + 2)", $0.element, style: 1))
      }
      .joined()

    let loaded = try load(Workbook.bytes(sheets: [SheetSpec("S", rows)], styles: [0, 14]))

    XCTAssertEqual(
      (0..<serials.count).map { loaded.text($0, "when") },
      [
        "1900-01-00", "1900-01-01", "1900-02-28", "1900-02-29", "1900-03-01", "2000-01-01",
        "2023-01-01", "2023-01-01", "1900-01-00", "-1",
      ])
  }

  /// Catches the 1904 workbook flag being ignored, which shifts every date by four years.
  func testDatesShowUnderTheNineteenHundredFourSystem() throws {
    let serials = ["0", "1", "366", "1462", "43465"]
    let rows =
      Workbook.row(1, cell("A1", "when", type: "str"))
      + serials.enumerated().map {
        Workbook.row($0.offset + 2, cell("A\($0.offset + 2)", $0.element, style: 1))
      }
      .joined()

    let loaded = try load(
      Workbook.bytes(sheets: [SheetSpec("S", rows)], styles: [0, 14], date1904: true))

    XCTAssertEqual(
      (0..<serials.count).map { loaded.text($0, "when") },
      ["1904-01-01", "1904-01-02", "1905-01-01", "1908-01-02", "2023-01-01"])
  }

  /// Catches a number format that is a date being shown as a number, and the reverse.
  func testOnlyDateFormatsTurnNumbersIntoDates() throws {
    let rows =
      Workbook.row(
        1,
        cell("A1", "d", type: "str") + cell("B1", "t", type: "str") + cell("C1", "dt", type: "str")
          + cell("D1", "p", type: "str") + cell("E1", "e", type: "str"))
      + Workbook.row(
        2,
        cell("A2", "44927.5", style: 1) + cell("B2", "0.75", style: 2)
          + cell("C2", "44927.5", style: 3) + cell("D2", "44927.5", style: 4)
          + cell("E2", "1.5", style: 5))

    let loaded = try load(
      Workbook.bytes(
        sheets: [SheetSpec("S", rows)], styles: [0, 14, 21, 164, 165, 46],
        formats: [164: "yyyy-mm-dd hh:mm", 165: "0.00%\"d\""]))

    XCTAssertEqual(loaded.text(0, "d"), "2023-01-01")
    XCTAssertEqual(loaded.text(0, "t"), "18:00:00")
    XCTAssertEqual(loaded.text(0, "dt"), "2023-01-01 12:00:00")
    XCTAssertEqual(loaded.text(0, "p"), "44927.5")
    XCTAssertEqual(loaded.text(0, "e"), "36:00:00")
    XCTAssertEqual(loaded.kind(0, "p"), .number)
  }

  // MARK: Sheets

  /// Catches a picker that lists hidden sheets, or a restore that fails on a sheet that is gone.
  func testSheetPickerListsVisibleWorksheetsAndLoadsTheNamedOne() throws {
    let book = Workbook.bytes(sheets: [
      SheetSpec("First", Workbook.row(1, cell("A1", "one", type: "str"))),
      SheetSpec("Secret", Workbook.row(1, cell("A1", "hidden", type: "str")), isHidden: true),
      SheetSpec("Third", Workbook.row(1, cell("A1", "three", type: "str"))),
    ])

    let first = try load(book)

    XCTAssertEqual(first.progress.sheets, ["First", "Third"])
    XCTAssertEqual(first.progress.selectedSheet, "First")
    XCTAssertEqual(first.titles, ["one"])

    let third = try load(book, sheet: "Third")

    XCTAssertEqual(third.progress.selectedSheet, "Third")
    XCTAssertEqual(third.titles, ["three"])

    let gone = try load(book, sheet: "Deleted")

    XCTAssertEqual(gone.progress.selectedSheet, "First")
    XCTAssertEqual(gone.end, .completed)
  }

  /// Catches a header rule that eats a data row, and columns that lose their identity.
  func testHeaderRowsFollowOneRule() throws {
    let labels = try load(
      Workbook.bytes(sheets: [
        SheetSpec(
          "S",
          Workbook.row(
            1,
            cell("A1", "amount", type: "str") + cell("C1", "amount", type: "str"))
            + Workbook.row(2, cell("A2", "1") + cell("B2", "2") + cell("C2", "3")))
      ]))

    XCTAssertEqual(labels.titles, ["amount", "Column 2", "amount"])
    XCTAssertEqual(
      labels.snapshot.columns.map(\.identity),
      [.named("amount"), .positional(1), .named("amount", occurrence: 1)])
    XCTAssertEqual(labels.rows, [["1", "2", "3"]])

    let numbers = try load(
      Workbook.bytes(sheets: [
        SheetSpec("S", Workbook.row(1, cell("A1", "10") + cell("B1", "x", type: "str")))
      ]))

    XCTAssertEqual(numbers.titles, ["Column 1", "Column 2"])
    XCTAssertEqual(numbers.rows, [["10", "x"]])
  }

  func testAnEmptySheetCompletesWithNoColumns() throws {
    let loaded = try load(Workbook.bytes(sheets: [SheetSpec("S", "")]))

    XCTAssertEqual(loaded.end, .completed)
    XCTAssertEqual(loaded.snapshot.columns.count, 0)
    XCTAssertEqual(loaded.progress.sheets, ["S"])
  }

  // MARK: Formats the viewer names and refuses

  /// Catches a refusal that says "corrupt", or that opens a file it cannot read.
  func testOtherSpreadsheetFormatsAreNamedByContent() throws {
    let cases: [(String, [UInt8], UnsupportedSpreadsheet)] = [
      ("old.xls", CompoundFixture.bytes(streams: ["Root Entry", "Workbook"]), .legacyXLS),
      (
        "locked.xlsx",
        CompoundFixture.bytes(streams: ["Root Entry", "EncryptionInfo", "EncryptedPackage"]),
        .passwordProtected
      ),
      (
        "renamed.xlsx", CompoundFixture.bytes(streams: ["Root Entry", "WordDocument"]),
        .otherOfficeFile
      ),
      (
        "binary.xlsb",
        ZipFixture.archive([
          ZipPart("[Content_Types].xml", "<Types/>"),
          ZipPart(
            "_rels/.rels",
            #"<Relationships><Relationship Id="r" Type="x/officeDocument" Target="xl/workbook.bin"/></Relationships>"#
          ),
          ZipPart("xl/workbook.bin", bytes: [1, 2, 3]),
        ]), .binaryXLSB
      ),
    ]

    for (name, bytes, kind) in cases {
      let loaded = try load(bytes, name: name)

      guard case .unsupportedSpreadsheet(_, let found)? = failure(loaded) else {
        XCTFail("\(name) ended \(loaded.end)")
        continue
      }

      XCTAssertEqual(found, kind, name)

      let message = failure(loaded)?.errorDescription ?? ""

      XCTAssertFalse(message.lowercased().contains("corrupt"), message)
      XCTAssertTrue(message.contains(kind.description), message)
    }
  }

  /// Catches an `.xlsm` that is refused, and a macro part that is read.
  func testMacroEnabledWorkbooksOpenWithTheirMacrosIgnored() throws {
    let rows = Workbook.row(1, cell("A1", "h", type: "str")) + Workbook.row(2, cell("A2", "1"))

    let loaded = try load(
      Workbook.bytes(
        sheets: [SheetSpec("S", rows)],
        extra: [ZipPart("xl/vbaProject.bin", bytes: [0xD0, 0xCF, 0x11, 0xE0])]),
      name: "macros.xlsm")

    XCTAssertEqual(loaded.end, .completed)
    XCTAssertEqual(loaded.rows, [["1"]])
  }

  func testFilesThatAreNotWorkbooksSayWhatTheyAre() throws {
    let text = try load(Array("a,b\n1,2\n".utf8), name: "data.xlsx")

    XCTAssertEqual(
      failure(text),
      .invalidSpreadsheet(
        path: failurePath(text), reason: "it is not a ZIP archive, which every .xlsx file is"))

    let noEnd = try load([0x50, 0x4B, 0x03, 0x04] + [UInt8](repeating: 0, count: 600))

    XCTAssertEqual(
      failure(noEnd),
      .invalidSpreadsheet(path: failurePath(noEnd), reason: "its ZIP directory is missing"))

    let document = try load(
      ZipFixture.archive([
        ZipPart(
          "_rels/.rels",
          #"<Relationships><Relationship Id="r" Type="x/officeDocument" Target="word/document.xml"/></Relationships>"#
        ),
        ZipPart("word/document.xml", "<document/>"),
      ]))

    XCTAssertEqual(
      failure(document),
      .invalidSpreadsheet(
        path: failurePath(document), reason: "the archive holds a document, not an Excel workbook"))
  }

  private func failurePath(_ loaded: Loaded) -> String {
    switch failure(loaded) {
    case .invalidSpreadsheet(let path, _): return path
    default: return ""
    }
  }

  // MARK: Caps

  private func sheetXML(_ body: String) -> [UInt8] {
    Array(
      (Workbook.header
        + #"<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>"#
        + body + "</sheetData></worksheet>").utf8)
  }

  /// A minimal workbook around one sheet part and, optionally, one shared strings part. The parts
  /// are written as given, so a test can make them hostile.
  private func rawWorkbook(
    sheet: ZipPart, strings: ZipPart? = nil, claimedSize: UInt32? = nil
  ) -> [UInt8] {
    let relationships =
      #"<Relationship Id="r1" Type="x/worksheet" Target="worksheets/sheet1.xml"/>"#
      + (strings == nil
        ? "" : #"<Relationship Id="r2" Type="x/sharedStrings" Target="sharedStrings.xml"/>"#)

    return ZipFixture.archive(
      [
        ZipPart(
          "_rels/.rels",
          Workbook.header
            + #"<Relationships><Relationship Id="r" Type="x/officeDocument" Target="xl/workbook.xml"/></Relationships>"#
        ),
        ZipPart(
          "xl/workbook.xml",
          Workbook.header
            + #"<workbook xmlns:r="x"><sheets><sheet name="S" r:id="r1"/></sheets></workbook>"#),
        ZipPart(
          "xl/_rels/workbook.xml.rels",
          Workbook.header + "<Relationships>\(relationships)</Relationships>"),
        sheet,
      ] + (strings.map { [$0] } ?? []))
  }

  /// Catches a cap that trusts the archive's size, or one that waits for the whole entry.
  func testInflatedBytesPassingTheCapStopTheLoadWhateverTheArchiveClaims() throws {
    let padding = String(repeating: " ", count: 8 << 20)
    let sheet = ZipPart(
      "xl/worksheets/sheet1.xml", bytes: sheetXML(padding), claimedSize: 100)

    var limits = SpreadsheetLimits()
    limits.sheetBytes = 1 << 20

    let loaded = try load(rawWorkbook(sheet: sheet), limits: limits)

    guard case .spreadsheetTooLarge(_, let what)? = failure(loaded) else {
      return XCTFail("expected the size cap, got \(loaded.end)")
    }

    XCTAssertTrue(what.contains("its sheet expanded past 1 MB"), what)
  }

  /// Catches a stored entry that claims more bytes than the file holds, which would otherwise loop.
  func testAStoredEntryLongerThanTheFileEndsWithAMessage() throws {
    let sheet = ZipPart(
      "xl/worksheets/sheet1.xml", bytes: sheetXML(""), method: .stored, claimedSize: .max)

    let loaded = try load(rawWorkbook(sheet: sheet))

    guard case .invalidSpreadsheet? = failure(loaded) else {
      return XCTFail("expected a message, got \(loaded.end)")
    }
  }

  /// Catches a shared strings table that has no cap of its own and grows with the file.
  func testSharedStringsHaveTheirOwnCap() throws {
    let table =
      Workbook.header + "<sst>"
      + String(repeating: "<si><t>some text</t></si>", count: 4_000) + "</sst>"

    var limits = SpreadsheetLimits()
    limits.sharedStringBytes = 16 << 10

    let loaded = try load(
      rawWorkbook(
        sheet: ZipPart("xl/worksheets/sheet1.xml", bytes: sheetXML("")),
        strings: ZipPart("xl/sharedStrings.xml", table)),
      limits: limits)

    guard case .spreadsheetTooLarge(_, let what)? = failure(loaded) else {
      return XCTFail("expected the size cap, got \(loaded.end)")
    }

    XCTAssertTrue(what.contains("shared strings table"), what)
  }

  /// Catches a table that is charged to nothing. The budget refuses it, so the load stops. A budget
  /// refusal is not a hostile file, so it ends like a CSV load that ran out of budget and never
  /// reports an expansion cap.
  func testSharedStringsAreChargedToTheBudget() throws {
    let table =
      Workbook.header + "<sst>"
      + String(repeating: "<si><t>some text</t></si>", count: 4_000) + "</sst>"

    let budget = TableBudget(limit: 4_096, floor: 0)

    let loaded = try load(
      rawWorkbook(
        sheet: ZipPart("xl/worksheets/sheet1.xml", bytes: sheetXML("")),
        strings: ZipPart("xl/sharedStrings.xml", table)),
      budget: budget)

    XCTAssertEqual(loaded.end, .stoppedAtBudget)
    XCTAssertNil(failure(loaded))
    XCTAssertEqual(budget.used, 0)
  }

  /// Catches a memory-pressure warning during the shared strings that reads as a hostile file.
  func testSharedStringsStopOnMemoryPressureLikeAnyOtherLoad() throws {
    let table =
      Workbook.header + "<sst>"
      + String(repeating: "<si><t>some text</t></si>", count: 4_000) + "</sst>"

    let loaded = try load(
      rawWorkbook(
        sheet: ZipPart("xl/worksheets/sheet1.xml", bytes: sheetXML("")),
        strings: ZipPart("xl/sharedStrings.xml", table)),
      afterLease: { $0.memoryPressureWarning() })

    XCTAssertEqual(loaded.end, .stoppedLowMemory)
  }

  /// Catches a row that holds a cut shared string and is not counted. The notice counts rows, as it
  /// does for CSV, so two rows that use one cut string count twice and a row of whole strings does
  /// not count.
  func testRowsThatUseACutSharedStringAreCounted() throws {
    var limits = SpreadsheetLimits()
    limits.cellBytes = 8

    let strings =
      Workbook.header
      + "<sst><si><t>h</t></si><si><t>0123456789</t></si><si><t>ok</t></si></sst>"

    let rows =
      Workbook.row(1, cell("A1", "0", type: "s"))
      + Workbook.row(2, cell("A2", "1", type: "s"))
      + Workbook.row(3, cell("A3", "1", type: "s") + cell("B3", "2", type: "s"))
      + Workbook.row(4, cell("A4", "2", type: "s"))

    let loaded = try load(
      Workbook.bytes(sheets: [SheetSpec("S", rows)], stringsXML: strings), limits: limits)

    XCTAssertEqual(loaded.end, .completed)
    XCTAssertEqual(loaded.progress.truncatedRows, 2)
  }

  /// Catches an entity declaration reaching the parser. A billion-laughs table must never expand.
  func testEntityDeclarationsAreRefusedBeforeTheyExpand() throws {
    let laughs =
      Workbook.header
      + #"<!DOCTYPE lolz [<!ENTITY a "aaaaaaaaaa"><!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;">]>"#
      + "<worksheet><sheetData><row><c t=\"inlineStr\"><is><t>&b;</t></is></c></row></sheetData></worksheet>"

    let loaded = try load(
      rawWorkbook(sheet: ZipPart("xl/worksheets/sheet1.xml", laughs)))

    XCTAssertEqual(
      failure(loaded),
      .invalidSpreadsheet(
        path: failurePath(loaded), reason: "it declares XML entities, which a workbook never does"))

    let external =
      Workbook.header
      + #"<!DOCTYPE x [<!ENTITY e SYSTEM "file:///etc/passwd">]><worksheet><sheetData><row><c t="inlineStr"><is><t>&e;</t></is></c></row></sheetData></worksheet>"#

    let second = try load(
      rawWorkbook(sheet: ZipPart("xl/worksheets/sheet1.xml", external)))

    XCTAssertEqual(
      failure(second),
      .invalidSpreadsheet(
        path: failurePath(second), reason: "it declares XML entities, which a workbook never does"))
  }

  /// Catches nesting with no bound. Each level is one element, so a small file can ask for millions.
  func testDeeplyNestedXMLStopsAtTheDepthCap() throws {
    let deep = String(repeating: "<g>", count: 5_000)

    let loaded = try load(
      rawWorkbook(sheet: ZipPart("xl/worksheets/sheet1.xml", bytes: sheetXML(deep))))

    guard case .spreadsheetTooLarge(_, let what)? = failure(loaded) else {
      return XCTFail("expected the depth cap, got \(loaded.end)")
    }

    XCTAssertTrue(what.contains("nests deeper than 64 levels"), what)
  }

  /// Catches a cell with no cap, and a cell reference past the last column. The first row is the
  /// header here, so the cut text shows as a column title.
  func testOversizedCellsAndColumnsAreCutAndCounted() throws {
    var limits = SpreadsheetLimits()
    limits.cellBytes = 8

    let rows =
      Workbook.row(
        1, #"<c r="A1" t="inlineStr"><is><t>0123456789</t></is></c>"# + cell("XFE1", "5"))
      + Workbook.row(2, cell("B2", "6"))

    let loaded = try load(Workbook.bytes(sheets: [SheetSpec("S", rows)]), limits: limits)

    XCTAssertEqual(loaded.end, .completed)
    XCTAssertEqual(loaded.titles.first, "01234567")
    XCTAssertEqual(loaded.snapshot.columns.count, 2)
    XCTAssertEqual(loaded.progress.truncatedRows, 1)
  }

  // MARK: Streaming

  /// Catches a reader that inflates a whole sheet before it parses. The sheet below inflates to
  /// several megabytes, yet no chunk the parser is fed is bigger than the pipe.
  func testASheetStreamsInChunksNoBiggerThanThePipe() throws {
    let rowXML = #"<row r="1"><c r="A1" s="0"/></row>"#
    let body = String(repeating: rowXML, count: 120_000)
    let sheet = ZipPart("xl/worksheets/sheet1.xml", bytes: sheetXML(body))

    let sizes = ChunkLog()
    var limits = SpreadsheetLimits()
    limits.observeChunk = { sizes.add($0) }

    let loaded = try load(rawWorkbook(sheet: sheet), limits: limits)

    XCTAssertEqual(loaded.end, .completed)
    XCTAssertEqual(loaded.snapshot.rowCount, 0)
    XCTAssertGreaterThan(sizes.total, 4_000_000)
    XCTAssertLessThanOrEqual(sizes.largest, XMLPart.chunkSize)
  }

  /// Catches rows that are not charged. A sheet bigger than the budget stops, and the budget never
  /// holds more than its limit.
  func testRowsStopAtTheBudgetAndStayCharged() throws {
    let rows = (1...4_000).map {
      Workbook.row($0, cell("A\($0)", "\($0)") + cell("B\($0)", "text", type: "str"))
    }.joined()

    let budget = TableBudget(limit: 32 << 10, floor: 0)
    let loaded = try load(
      Workbook.bytes(sheets: [SheetSpec("S", rows)]), budget: budget, pageTarget: 4 << 10)

    XCTAssertEqual(loaded.end, .stoppedAtBudget)
    XCTAssertGreaterThan(loaded.snapshot.rowCount, 0)
    XCTAssertLessThan(loaded.snapshot.rowCount, 4_000)
    XCTAssertLessThanOrEqual(budget.used, 32 << 10)
  }

  /// Catches a part that is gathered whole before it is parsed. The sheet below inflates to about
  /// 5 MB, and the load is cancelled after the first rows. A reader that buffered the part would
  /// have inflated all of it by then. A streaming one has inflated only what the pipe holds.
  func testStoppingEarlyInflatesOnlyAFractionOfTheSheet() throws {
    let rowXML = #"<row r="1"><c r="A1"><v>1</v></c></row>"#
    let body = String(repeating: rowXML, count: 120_000)
    let sheet = ZipPart("xl/worksheets/sheet1.xml", bytes: sheetXML(body))

    let sizes = ChunkLog()
    var limits = SpreadsheetLimits()
    limits.observeChunk = { sizes.add($0) }

    let counter = Counter()
    let loaded = try load(
      rawWorkbook(sheet: sheet), limits: limits, isCancelled: { counter.next() > 1 })

    XCTAssertEqual(loaded.end, .cancelled)
    XCTAssertGreaterThan(sizes.total, 0)
    XCTAssertLessThan(sizes.total, 1 << 20, "the reader inflated far more than it parsed")
  }

  /// Catches a flipped byte in cell text that still parses. The load must fail with a message
  /// that says the data is corrupt, not show a wrong value.
  func testAFlippedByteInAStoredPartFailsTheChecksum() throws {
    var bytes = Workbook.bytes(
      sheets: [SheetSpec("S", Workbook.row(1, cell("A1", "marker", type: "str")))])

    let needle = Array("<v>marker</v>".utf8)

    // The archive stores parts deflated, so rebuild this one with stored parts and flip a letter.
    var parts = try XCTUnwrap(ZipFixture.parts(of: bytes))

    for index in parts.indices { parts[index].method = .stored }

    bytes = ZipFixture.archive(parts)

    let at = try XCTUnwrap(bytes.firstRange(of: needle)).lowerBound + 4
    bytes[at] = UInt8(ascii: "M")

    let loaded = try load(bytes)

    guard case .invalidSpreadsheet(_, let reason)? = failure(loaded) else {
      return XCTFail("expected a checksum failure, got \(loaded.end)")
    }

    XCTAssertTrue(reason.contains("corrupt"), reason)
  }

  /// Catches a reference with a long letter run that is placed in the next free column instead of
  /// being cut like any column past the last.
  func testAColumnReferenceWiderThanTheSheetIsCutNotPlaced() throws {
    let rows =
      Workbook.row(1, cell("A1", "h", type: "str") + cell("B1", "i", type: "str"))
      + Workbook.row(2, cell("A2", "1") + cell("ABCDE2", "2") + cell("AAAA7", "3"))

    let loaded = try load(Workbook.bytes(sheets: [SheetSpec("S", rows)]))

    XCTAssertEqual(loaded.rows, [["1", ""]])
    XCTAssertEqual(loaded.progress.truncatedRows, 1)
  }

  /// Catches two sheets with one name, where the second cannot be picked.
  func testSheetsWithTheSameNameAreNumbered() throws {
    let book = Workbook.bytes(sheets: [
      SheetSpec("A", Workbook.row(1, cell("A1", "first", type: "str"))),
      SheetSpec("A", Workbook.row(1, cell("A1", "second", type: "str"))),
    ])

    let first = try load(book)

    XCTAssertEqual(first.progress.sheets, ["A", "A (2)"])
    XCTAssertEqual(first.titles, ["first"])

    let second = try load(book, sheet: "A (2)")

    XCTAssertEqual(second.progress.selectedSheet, "A (2)")
    XCTAssertEqual(second.titles, ["second"])
  }

  /// Catches a compound file whose directory walk fails midway being named from the part it did
  /// read. A truncated `.xls` is still read as `.xls`.
  func testATruncatedCompoundFileIsStillNamedAsALegacyWorkbook() throws {
    let whole = CompoundFixture.bytes(streams: ["Root Entry", "WordDocument"])
    let cut = Array(whole.prefix(1_024))

    let loaded = try load(cut, name: "cut.xls")

    guard case .unsupportedSpreadsheet(_, let kind)? = failure(loaded) else {
      return XCTFail("expected a named format, got \(loaded.end)")
    }

    XCTAssertEqual(kind, .legacyXLS)
  }

  func testCancellingStopsTheRead() throws {
    let rows = (1...2_000).map { Workbook.row($0, cell("A\($0)", "1")) }.joined()
    let counter = Counter()

    let loaded = try load(
      Workbook.bytes(sheets: [SheetSpec("S", rows)]),
      isCancelled: { counter.next() > 3 })

    XCTAssertEqual(loaded.end, .cancelled)
  }
}

private final class ChunkLog: @unchecked Sendable {
  private let lock = NSLock()
  private var sizes: [Int] = []

  func add(_ size: Int) {
    lock.withLock { sizes.append(size) }
  }

  var total: Int { lock.withLock { sizes.reduce(0, +) } }
  var largest: Int { lock.withLock { sizes.max() ?? 0 } }
}

private final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0

  func next() -> Int {
    lock.withLock {
      value += 1
      return value
    }
  }
}
