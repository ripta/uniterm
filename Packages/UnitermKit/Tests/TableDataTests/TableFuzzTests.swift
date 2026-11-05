import Foundation
import TableTestSupport
import XCTest

@testable import TableData

/// A seeded mutation fuzzer for the table readers as shipped. The CSV side covers the encoding pick,
/// the transcoder, the delimiter sniffer, the parser, the page store, and the sort and filter over
/// it. The JSON side covers the scanner, the flattening, the column registry, and the nested
/// values a cell opens. The workbook side builds `.xlsx` archives in code and mutates their parts,
/// their directory, and their compound-file lookalikes. It covers the ZIP reader, the inflating
/// thread, the XML parts, and the caps, with the limits shrunk so a small file reaches them.
///
/// `make test-package` runs it at a small count. `make fuzz` runs it under the address sanitizer
/// at a large one, through `UNITERM_FUZZ_ITERATIONS`. `UNITERM_FUZZ_SEED` repeats a run. A failure
/// names the seed and the iteration, and writes the input to the test's scratch folder.
///
/// It proves that no mutated input traps, reads out of bounds, or breaks the store's own
/// invariants. It cannot prove the cells are right. The loader and parser tests prove that.
/// ASan does not instrument the system libraries the way it does Swift. A workbook passes through
/// libxml2 and the Compression framework, which the sanitizer sees only through its allocator and
/// memory-function interceptors. A heap overflow in their own code can go unseen, so a clean run
/// here is weaker evidence than one over Swift code.
final class TableFuzzTests: XCTestCase {
  private var iterations: Int {
    ProcessInfo.processInfo.environment["UNITERM_FUZZ_ITERATIONS"].flatMap(Int.init) ?? 300
  }

  private var seed: UInt64 {
    ProcessInfo.processInfo.environment["UNITERM_FUZZ_SEED"].flatMap(UInt64.init) ?? 0x5EED
  }

  /// Catches an input that makes the loader trap or leaves the store inconsistent.
  func testMutatedFilesLoadWithoutTrappingAndKeepTheStoreConsistent() throws {
    let scratch = try Scratch(self)
    var random = SplitMix64(seed: seed)
    let corpus = Self.corpus()

    for iteration in 0..<iterations {
      var input = corpus[Int(random.next() % UInt64(corpus.count))]

      for _ in 0..<(1 + Int(random.next() % 6)) {
        Self.mutate(&input, using: &random)
      }

      let name = random.next() % 7 == 0 ? "fuzz.tsv" : "fuzz.csv"
      let file = try scratch.write(name, input)
      let context = "seed \(seed), iteration \(iteration), input kept at \(file.path)"

      let pageTarget = [64, 512, 4096, TableLoader.defaultPageTarget][Int(random.next() % 4)]
      let limit = random.next() % 5 == 0 ? 2_000 : 1 << 30
      let loaded = loadFile(
        file, budget: TableBudget(limit: limit, floor: 0), pageTarget: pageTarget)

      switch loaded.end {
      case .completed, .stoppedAtBudget:
        break

      default:
        XCTFail("unexpected end \(loaded.end), \(context)")
        continue
      }

      try Self.check(loaded.snapshot, using: &random, context: context)
    }
  }

  /// Catches a parser whose rows depend on where the reads split. Random splits of mutated input
  /// give the rows of the whole input.
  func testRandomChunkingNeverChangesTheRows() {
    var random = SplitMix64(seed: seed &+ 1)
    let corpus = Self.corpus()

    for iteration in 0..<iterations {
      var input = corpus[Int(random.next() % UInt64(corpus.count))]

      for _ in 0..<(1 + Int(random.next() % 4)) {
        Self.mutate(&input, using: &random)
      }

      func rows(chunked: Bool, using random: inout SplitMix64) -> [[UInt8]] {
        var parser = CSVParser(delimiter: UInt8(ascii: ","))
        var rows: [[UInt8]] = []

        let sink: CSVParser.Sink = { row, ends in
          rows.append(row + ends.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8 & 0xFF)] })
          return true
        }

        var offset = 0
        while offset < input.count {
          let size = chunked ? 1 + Int(random.next() % 64) : input.count
          parser.feed(input[offset..<min(offset + size, input.count)], sink: sink)
          offset += size
        }

        parser.finish(sink: sink)
        return rows
      }

      let whole = rows(chunked: false, using: &random)
      let split = rows(chunked: true, using: &random)

      XCTAssertEqual(whole, split, "seed \(seed &+ 1), iteration \(iteration)")
    }
  }

  /// Catches an input that makes the JSON reader trap, ends it some way other than a table or a
  /// syntax message, or leaves the store inconsistent. Every nested cell it finds must open.
  func testMutatedJSONFilesLoadWithoutTrappingAndKeepTheStoreConsistent() throws {
    let scratch = try Scratch(self)
    var random = SplitMix64(seed: seed &+ 2)
    let corpus = Self.jsonCorpus()

    for iteration in 0..<iterations {
      var input = corpus[Int(random.next() % UInt64(corpus.count))]

      for _ in 0..<(1 + Int(random.next() % 6)) {
        Self.mutate(&input, using: &random, interesting: Self.jsonInteresting)
      }

      let file = try scratch.write(random.next() % 3 == 0 ? "fuzz.jsonl" : "fuzz.json", input)
      let context = "seed \(seed &+ 2), iteration \(iteration), input kept at \(file.path)"

      let pageTarget = [64, 512, 4096, TableLoader.defaultPageTarget][Int(random.next() % 4)]
      let limit = random.next() % 5 == 0 ? 2_000 : 1 << 30
      let loaded = loadFile(
        file, budget: TableBudget(limit: limit, floor: 0), pageTarget: pageTarget)

      switch loaded.end {
      case .completed, .stoppedAtBudget, .failed(.invalidJSON), .failed(.notATable):
        break

      default:
        XCTFail("unexpected end \(loaded.end), \(context)")
        continue
      }

      try Self.check(loaded.snapshot, using: &random, context: context)
      Self.checkNestedCells(in: loaded.snapshot, context: context)
    }
  }

  /// Catches a scanner whose events depend on where the reads split. Random splits of mutated
  /// JSON give the events of the whole input, in both modes.
  func testRandomChunkingNeverChangesTheJSONEvents() {
    var random = SplitMix64(seed: seed &+ 3)
    let corpus = Self.jsonCorpus()

    for iteration in 0..<iterations {
      var input = corpus[Int(random.next() % UInt64(corpus.count))]

      for _ in 0..<(1 + Int(random.next() % 4)) {
        Self.mutate(&input, using: &random, interesting: Self.jsonInteresting)
      }

      let mode: JSONScanner.Mode = random.next() % 2 == 0 ? .single : .lines
      let capture = mode == .lines ? 1 : 2
      let whole = scanEvents([input[...]], mode: mode, captureAt: capture)

      var chunks: [ArraySlice<UInt8>] = []
      var offset = 0

      while offset < input.count {
        let size = 1 + Int(random.next() % 64)
        chunks.append(input[offset..<min(offset + size, input.count)])
        offset += size
      }

      XCTAssertEqual(
        scanEvents(chunks, mode: mode, captureAt: capture), whole,
        "seed \(seed &+ 3), iteration \(iteration)")
    }
  }

  /// Catches a workbook that makes the reader trap, hang, or leave the store inconsistent, and a
  /// failure that is not one of the messages the pane shows. A workbook that loads must also keep
  /// the budget's accounting honest.
  func testMutatedWorkbooksLoadWithoutTrappingAndKeepTheStoreConsistent() throws {
    let scratch = try Scratch(self)
    var random = SplitMix64(seed: seed &+ 4)
    let corpus = Self.workbookCorpus()

    for iteration in 0..<iterations {
      var item = corpus[Int(random.next() % UInt64(corpus.count))]

      for _ in 0..<(1 + Int(random.next() % 4)) {
        guard !item.parts.isEmpty else { break }

        let index = Int(random.next() % UInt64(item.parts.count))

        Self.mutate(&item.parts[index].data, using: &random, interesting: Self.xmlInteresting)
      }

      var bytes = item.raw ?? ZipFixture.archive(item.parts)

      if item.raw != nil || random.next() % 8 == 0 {
        Self.mutate(&bytes, using: &random, interesting: Self.interesting)
      }

      let file = try scratch.write(
        ["fuzz.xlsx", "fuzz.xlsm", "fuzz.xls"][Int(random.next() % 3)], bytes)
      let context = "seed \(seed &+ 4), iteration \(iteration), input kept at \(file.path)"

      var limits = SpreadsheetLimits()

      if random.next() % 4 != 0 {
        limits.metadataBytes = 4 << 10
        limits.sharedStringBytes = 32 << 10
        limits.sheetBytes = 1 << 20
        limits.cellBytes = 64
        limits.rowCells = 200
        limits.rowBytes = 4 << 10
        limits.entries = 64
        limits.depth = 24
      }

      let pageTarget = [64, 512, 4096, TableLoader.defaultPageTarget][Int(random.next() % 4)]
      let budget = TableBudget(limit: random.next() % 5 == 0 ? 4_000 : 1 << 30, floor: 0)
      let sheet = random.next() % 3 == 0 ? "Second" : nil
      let log = EventLog()

      TableLoader.loadBlocking(
        .file(file, sheet: sheet), lease: budget.makeLease(), pageTarget: pageTarget,
        limits: limits, emit: log.add)

      guard case .finished(let snapshot, let end, _)? = log.events.last else {
        XCTFail("no finished event, \(context)")
        continue
      }

      switch end {
      case .completed, .stoppedAtBudget,
        .failed(.invalidSpreadsheet), .failed(.spreadsheetTooLarge),
        .failed(.unsupportedSpreadsheet):
        break

      default:
        XCTFail("unexpected end \(end), \(context)")
        continue
      }

      try Self.check(snapshot, using: &random, context: context, scanRows: 100, scanColumns: 256)
    }
  }

  // MARK: Invariants

  /// Every nested cell is valid JSON that the reader already checked, so it must open as a table.
  /// A few per snapshot keep the cost down.
  private static func checkNestedCells(in snapshot: TableSnapshot, context: String) {
    var opened = 0

    for row in 0..<snapshot.rowCount where opened < 4 {
      for column in 0..<snapshot.columns.count where opened < 4 {
        guard snapshot.kind(row: row, column: column) == .nested else { continue }

        opened += 1

        let value = loadSource(
          .embeddedJSON(name: "cell", bytes: Array(snapshot.cell(row: row, column: column))))

        XCTAssertEqual(value.end, .completed, "nested cell \(row),\(column), \(context)")
      }
    }
  }

  /// Walks the cells and runs a few sorts and a filter. A workbook can be 16,384 columns wide, so
  /// the walk covers `scanRows` rows and `scanColumns` columns, and only that many rows of the
  /// filter's answer are checked against every column.
  private static func check(
    _ snapshot: TableSnapshot, using random: inout SplitMix64, context: String,
    scanRows: Int = .max, scanColumns: Int = .max
  ) throws {
    var cells = 0

    for row in 0..<min(snapshot.rowCount, scanRows) {
      for column in 0..<min(snapshot.columns.count, scanColumns) {
        cells += snapshot.cell(row: row, column: column).count
        _ = snapshot.text(row: row, column: column, limit: 16)
      }
    }

    XCTAssertEqual(snapshot.cell(row: snapshot.rowCount, column: 0).count, 0, context)

    let sampled = (0..<min(snapshot.columns.count, 6)).map { _ in
      snapshot.columns[Int(random.next() % UInt64(snapshot.columns.count))]
    }

    for column in sampled {
      for ascending in [true, false] {
        let query = TableQuery(sort: SortSpec(column: column.identity, ascending: ascending))

        guard case .rows(let rows)? = TableQueryEngine.evaluate(snapshot, query: query) else {
          XCTAssertEqual(snapshot.rowCount, 0, context)
          continue
        }

        XCTAssertEqual(rows.map(Int.init).sorted(), Array(0..<snapshot.rowCount), context)
      }
    }

    let needle = String(
      decoding: (0..<(1 + Int(random.next() % 2))).map { _ in
        UInt8(truncatingIfNeeded: 0x61 + random.next() % 6)
      }, as: UTF8.self)

    let selection = TableQueryEngine.evaluate(snapshot, query: TableQuery(filter: needle))

    for index in 0..<min(selection?.count ?? 0, scanRows) {
      let row = selection?.row(at: index) ?? 0
      let found = (0..<snapshot.columns.count).contains {
        snapshot.text(row: row, column: $0, limit: .max).lowercased().range(of: needle) != nil
      }

      XCTAssertTrue(found, "row \(row) does not hold \(needle), \(context)")
    }
  }

  // MARK: Corpus

  /// The seeds, written out in code since the repo holds no binary fixtures.
  private static func corpus() -> [[UInt8]] {
    let plain = "id,name,amount\n1,widget,9.50\n2,gadget,12\n3,gizmo,\n"
    let quoted = "a,b\n\"x,y\",\"line1\nline2\"\n\"say \"\"hi\"\"\",\"\"\n"
    let semicolons = "k;v\n1;one\n2;two\n"
    let tabs = "k\tv\n1\tone\n2\ttwo\n"
    let crlf = "h1,h2\r\n1,2\r\n\r\n3,4\r\n"
    let accents = "name,city\ncaf\u{E9},Z\u{FC}rich\n\u{20AC}5,\u{1F600}\n"

    let utf16 =
      [0xFF, 0xFE] as [UInt8]
      + accents.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
    let cp1252: [UInt8] = Array("name,price\ncaf".utf8) + [0xE9, 0x2C, 0x80, 0x35, 0x0A]
    let manyColumns = [UInt8](repeating: UInt8(ascii: ","), count: 70_000) + [0x0A]

    return [
      Array(plain.utf8), Array(quoted.utf8), Array(semicolons.utf8), Array(tabs.utf8),
      Array(crlf.utf8), [0xEF, 0xBB, 0xBF] + Array(accents.utf8), utf16, cp1252,
      Array("\"unterminated,quote\n1,2".utf8), Array("a,b\n1,2".utf8), [], [0x0A], manyColumns,
      [UInt8](repeating: UInt8(ascii: "\""), count: 33),
    ]
  }

  private static let interesting: [UInt8] = [
    0x2C, 0x22, 0x0D, 0x0A, 0x00, 0xFF, 0xC3, 0xE2, 0x80, 0x09, 0x3B, 0x7C, 0xFE, 0xEF, 0xBB, 0xBF,
    0xF0, 0x9F, 0xD8, 0xDC,
  ]

  /// The bytes that change a JSON document's structure or its tokens.
  private static let jsonInteresting: [UInt8] =
    Array("{}[]\":,\\-+.eEuntrfalsd09/ ".utf8) + [
      0x0A, 0x00, 0xFF, 0xC3, 0xED, 0xA0, 0xEF, 0xBB, 0xBF,
    ]

  // The JSON seeds, written out in code since the repo holds no binary fixtures.
  private static func jsonCorpus() -> [[UInt8]] {
    let texts = [
      #"[{"id":1,"name":"a","tags":["x"],"o":{"p":null}},{"id":2.5e3,"o":{"p":true}}]"#,
      "[\n  {\"a\": {\"b\": {\"c\": [1, {\"d\": 2}]}}},\n  {\"a\": 5}\n]\n",
      "{\"a\":1}\n{\"b\":[1,2]}\n3\n\"four\"\n",
      #"{"k":"v","n":[{"x":1}],"m":{"q":{}}}"#,
      "[[1,2,3],[4],[]]",
      #"[1,"two",null,false,-0,12345678901234567890,1e999]"#,
      #"["\u00e9\ud83d\ude00\ud800 \\ \/ \n \" \t"]"#,
      #"[{"a":1,"a":2,"b":{"c":3,"c":4}},{"a.b":1,"a":{"b":2}}]"#,
      "[]", "{}", "", "   \n", "42", #"[1,]"#, #"{"a" 1}"#,
      "[{" + [String](repeating: "\"a\":1", count: 3_000).joined(separator: ",") + "}]",
      "[{" + (0..<3_000).map { "\"w\($0)\":[\($0)]" }.joined(separator: ",") + "}]",
      "[[" + (0..<1_200).map(String.init).joined(separator: ",") + "]]",
      "[1" + String(repeating: "9", count: 70_000) + "]",
      String(repeating: "[", count: 300),
      String(repeating: "{\"a\":", count: 300),
      "[" + String(repeating: "[", count: 100) + String(repeating: "]", count: 100) + "]",
      "[{" + (0..<1_100).map { "\"k\($0)\":\($0)" }.joined(separator: ",") + "}]",
      "[{\"m\":{" + (0..<100).map { "\"id\($0)\":[\($0)]" }.joined(separator: ",") + "}}]",
    ]

    let accents = #"[{"name":"caf\#u{E9}","city":"Z\#u{FC}rich"}]"#

    return texts.map { Array($0.utf8) } + [
      [0xEF, 0xBB, 0xBF] + Array(accents.utf8),
      [0xFF, 0xFE] + accents.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] },
      Array("[\"\u{1}\"]".utf8),
    ]
  }

  /// The bytes that change an XML part's structure, its names, or its numbers.
  private static let xmlInteresting: [UInt8] =
    Array("<>/=\"'&;!-[]? :_xsrtvfcwb0123456789ABXFD".utf8) + [0x0A, 0x00, 0xFF, 0xC3, 0xEF, 0xBB]

  /// One workbook seed. `parts` are zipped after mutation. `raw` is a file that is not a workbook
  /// the builder can make, such as a compound file, and takes byte mutations only.
  private struct WorkbookSeed {
    var parts: [ZipPart] = []
    var raw: [UInt8]?
  }

  // The workbook seeds, written out in code since the repo holds no binary fixtures.
  private static func workbookCorpus() -> [WorkbookSeed] {
    func cell(_ ref: String, _ value: String, _ type: String? = nil, _ style: Int? = nil) -> String
    {
      let t = type.map { " t=\"\($0)\"" } ?? ""
      let s = style.map { " s=\"\($0)\"" } ?? ""

      return "<c r=\"\(ref)\"\(s)\(t)><v>\(value)</v></c>"
    }

    func seed(_ bytes: [UInt8]) -> WorkbookSeed {
      WorkbookSeed(parts: unzip(bytes))
    }

    let plain = Workbook.bytes(
      sheets: [
        SheetSpec(
          "First",
          Workbook.row(1, cell("A1", "0", "s") + cell("B1", "1", "s") + cell("C1", "2", "s"))
            + Workbook.row(
              2, cell("A2", "4.5") + cell("B2", "44927", nil, 1) + cell("C2", "1", "b"))
            + Workbook.row(3, "<c r=\"A3\"><f>A2*2</f></c>" + cell("C3", "#N/A", "e"))),
        SheetSpec(
          "Second", Workbook.row(1, cell("A1", "x", "str") + cell("B1", "y", "str")), isHidden: true
        ),
        SheetSpec("Third", Workbook.row(1, cell("A1", "z", "str"))),
      ], strings: ["alpha", "beta", "gamma"], styles: [0, 14, 22, 164], formats: [164: "h:mm"],
      date1904: false)

    let rich = Workbook.bytes(
      sheets: [
        SheetSpec(
          "S",
          Workbook.row(
            1,
            cell("A1", "0", "s") + cell("B1", "1", "s")
              + "<c r=\"C1\" t=\"inlineStr\"><is><r><t>in</t></r><rPh><t>x</t></rPh></is></c>"))
      ],
      stringsXML:
        "<sst><si><r><t>a_x0041_b</t></r><rPh sb=\"0\"><t>ph</t></rPh></si><si><t>_xD83D__xDE00_ _xZZZZ_ _x00</t></si></sst>"
    )

    let wide = Workbook.bytes(
      sheets: [
        SheetSpec(
          "W",
          Workbook.row(1, (0..<400).map { cell("A\($0 + 1)", "\($0)") }.joined())
            + Workbook.row(2, cell("XFD2", "1") + cell("XFE2", "2") + cell("A2", "3"))
            + Workbook.row(3, (0..<300).map { _ in cell("B3", "1") }.joined())
            + Workbook.row(4, cell("C4", "1") + cell("A4", "2") + cell("B4", "3")))
      ])

    let deep = Workbook.bytes(
      sheets: [
        SheetSpec("D", String(repeating: "<g>", count: 200) + Workbook.row(1, cell("A1", "1")))
      ])

    let doctype =
      Workbook.header
      + "<!DOCTYPE x [<!ENTITY a \"aaaaaaaaaa\"><!ENTITY b \"&a;&a;&a;&a;&a;&a;\">]>"
    let entities = Workbook.bytes(sheets: [
      SheetSpec("E", Workbook.row(1, "<c t=\"inlineStr\"><is><t>&b;</t></is></c>"))
    ])
    var entityParts = unzip(entities)
    entityParts[2].data = Array(
      (doctype + "<workbook><sheets><sheet name=\"E\" r:id=\"rId1\"/></sheets></workbook>").utf8)

    let manyStrings = Workbook.bytes(
      sheets: [SheetSpec("S", Workbook.row(1, cell("A1", "5", "s")))],
      stringsXML: "<sst>" + String(repeating: "<si><t>some shared text</t></si>", count: 3_000)
        + "</sst>")

    let bomb = ZipFixture.archive([
      ZipPart(
        "_rels/.rels",
        "<Relationships><Relationship Id=\"r\" Type=\"x/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>"
      ),
      ZipPart(
        "xl/workbook.xml",
        "<workbook xmlns:r=\"x\"><sheets><sheet name=\"B\" r:id=\"r1\"/></sheets></workbook>"),
      ZipPart(
        "xl/_rels/workbook.xml.rels",
        "<Relationships><Relationship Id=\"r1\" Type=\"x/worksheet\" Target=\"worksheets/s.xml\"/></Relationships>"
      ),
      ZipPart(
        "xl/worksheets/s.xml",
        bytes: Array("<worksheet><sheetData>".utf8) + [UInt8](repeating: 0x20, count: 3 << 20)
          + Array("</sheetData></worksheet>".utf8), claimedSize: 64),
    ])

    let broken = ZipFixture.archive([
      ZipPart(
        "_rels/.rels",
        "<Relationships><Relationship Id=\"r\" Type=\"x/officeDocument\" Target=\"../../x.xml\"/></Relationships>"
      ),
      ZipPart(
        "x.xml",
        "<workbook><sheets><sheet name=\"A\" r:id=\"r1\"/><sheet/><sheet name=\"A\"/></sheets></workbook>"
      ),
    ])

    return [
      seed(plain), seed(rich), seed(wide), seed(deep), WorkbookSeed(parts: entityParts),
      seed(manyStrings), seed(bomb), WorkbookSeed(raw: bomb), seed(broken),
      WorkbookSeed(raw: CompoundFixture.bytes(streams: ["Root Entry", "Workbook"])),
      WorkbookSeed(raw: CompoundFixture.bytes(streams: ["Root Entry", "EncryptedPackage"])),
      WorkbookSeed(raw: Array("PK".utf8) + [3, 4] + [UInt8](repeating: 0, count: 80)),
      WorkbookSeed(raw: ZipFixture.archive([])),
      WorkbookSeed(raw: ZipFixture.archive([ZipPart("xl/workbook.bin", bytes: [1])])),
      WorkbookSeed(raw: []),
    ]
  }

  /// The parts of an archive that `ZipFixture` wrote, so a test can mutate them and zip them again.
  private static func unzip(_ archive: [UInt8]) -> [ZipPart] {
    guard let parts = ZipFixture.parts(of: archive) else { return [] }

    return parts
  }

  private static func mutate(
    _ input: inout [UInt8], using random: inout SplitMix64, interesting: [UInt8]? = nil
  ) {
    let interesting = interesting ?? Self.interesting

    let size = input.count

    switch random.next() % 8 {
    case 0 where size > 0:
      input[Int(random.next() % UInt64(size))] ^= UInt8(1 << (random.next() % 8))

    case 1 where size > 0:
      input[Int(random.next() % UInt64(size))] =
        interesting[Int(random.next() % UInt64(interesting.count))]

    case 2:
      let at = Int(random.next() % UInt64(size + 1))
      let bytes = (0..<(1 + Int(random.next() % 8))).map { _ in
        interesting[Int(random.next() % UInt64(interesting.count))]
      }
      input.insert(contentsOf: bytes, at: at)

    case 3 where size > 0:
      let start = Int(random.next() % UInt64(size))
      let end = min(size, start + 1 + Int(random.next() % 16))
      input.removeSubrange(start..<end)

    case 4 where size > 0:
      let start = Int(random.next() % UInt64(size))
      let end = min(size, start + 1 + Int(random.next() % 64))
      input.insert(contentsOf: Array(input[start..<end]), at: end)

    case 5 where size > 0:
      input.removeLast(Int(random.next() % UInt64(size)))

    case 6:
      input.insert(
        contentsOf: [[0xEF, 0xBB, 0xBF], [0xFF, 0xFE], [0xFE, 0xFF]][Int(random.next() % 3)], at: 0)

    default:
      input.append(
        contentsOf: [UInt8](repeating: UInt8(ascii: "\""), count: Int(random.next() % 5)))
    }
  }
}
