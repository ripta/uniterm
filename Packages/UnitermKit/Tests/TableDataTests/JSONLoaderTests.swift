import XCTest

@testable import TableData

/// The JSON reader through the loader's production entry point, on real files. Expected tables
/// are written by hand from the rules in `JSONRule`.
final class JSONLoaderTests: XCTestCase {
  private func load(_ text: String, name: String = "a.json") throws -> Loaded {
    loadFile(try Scratch(self).write(name, text))
  }

  private func invalid(_ end: LoadEnd) -> (reason: String, line: Int)? {
    guard case .failed(.invalidJSON(_, let reason, let line)) = end else { return nil }

    return (reason, line)
  }

  // MARK: Flattening

  /// Catches a loader that drops nested values or shows them in the wrong place. Objects flatten
  /// to path columns in first-seen order, an array stays one expandable cell, and a key a row lacks
  /// is missing while a key set to null is null.
  func testAnArrayOfObjectsFlattensToOneColumnPerKeyPath() throws {
    let loaded = try load(
      """
      [{"id":1,"user":{"login":"ann","org":{"name":"x"}},"tags":["a","b"],"gone":null},
       {"id":2,"user":{"login":"bob"},"extra":true}]
      """)

    XCTAssertEqual(loaded.end, .completed)
    XCTAssertEqual(
      loaded.titles, ["id", "user.login", "user.org.name", "tags", "gone", "extra"])

    XCTAssertEqual(loaded.text(0, "user.org.name"), "x")
    XCTAssertEqual(loaded.text(0, "tags"), #"["a","b"]"#)
    XCTAssertEqual(loaded.kind(0, "tags"), .nested)
    XCTAssertEqual(loaded.kind(0, "gone"), .null)
    XCTAssertEqual(loaded.text(0, "gone"), "null")
    XCTAssertEqual(loaded.kind(0, "extra"), .missing)

    XCTAssertEqual(loaded.kind(1, "user.org.name"), .missing)
    XCTAssertEqual(loaded.kind(1, "gone"), .missing)
    XCTAssertEqual(loaded.text(1, "extra"), "true")
    XCTAssertEqual(loaded.kind(1, "extra"), .bool)
  }

  /// Catches a column named by a dotted string, which merges two different values. A key that
  /// holds a dot and a nested path that reads the same are two columns, and only the title
  /// escapes the dot.
  func testAColumnIsAKeySegmentListAndADotInAKeyIsEscapedOnlyInTheTitle() throws {
    let loaded = try load(#"[{"a.b":1,"a":{"b":2}}]"#)
    let columns = loaded.snapshot.columns

    XCTAssertEqual(columns.map(\.identity.segments), [["a.b"], ["a", "b"]])
    XCTAssertEqual(columns.map(\.title), [#"a\.b"#, "a.b"])
    XCTAssertEqual(loaded.rows, [["1", "2"]])
  }

  /// Catches a number that goes through a double and comes out rounded or reformatted.
  func testNumbersKeepTheirOriginalText() throws {
    let loaded = try load(
      #"[{"n":12345678901234567890,"d":1.000000000000000000001,"e":1E5,"z":-0.0}]"#)

    XCTAssertEqual(
      loaded.rows, [["12345678901234567890", "1.000000000000000000001", "1E5", "-0.0"]])
    XCTAssertEqual(loaded.kind(0, "n"), .number)
  }

  /// Catches a key that holds different shapes in different rows losing a value. The path
  /// column holds the scalars and the array, and the flattened column holds the object's member.
  func testAKeyThatChangesShapeKeepsEveryValue() throws {
    let loaded = try load(#"[{"a":{"b":1}},{"a":5},{"a":[1,2]},{"a":"s"}]"#)

    XCTAssertEqual(loaded.titles, ["a.b", "a"])
    XCTAssertEqual(loaded.text(0, "a.b"), "1")
    XCTAssertEqual(loaded.text(1, "a"), "5")
    XCTAssertEqual(loaded.text(2, "a"), "[1,2]")
    XCTAssertEqual(loaded.kind(2, "a"), .nested)
    XCTAssertEqual(loaded.text(3, "a"), "s")
    XCTAssertEqual(loaded.kind(3, "a"), .string)
  }

  /// Catches the documented duplicate-key rule. Every value is kept: the nth time a path repeats
  /// in a row it fills the path's nth column.
  func testDuplicateKeysKeepEveryValueInOccurrenceColumns() throws {
    let loaded = try load(#"[{"a":1,"a":2,"b":{"c":3,"c":4}}]"#)

    XCTAssertEqual(loaded.titles, ["a", "a", "b.c", "b.c"])
    XCTAssertEqual(
      loaded.snapshot.columns.map(\.identity),
      [
        ColumnIdentity(segments: ["a"], occurrence: 0),
        ColumnIdentity(segments: ["a"], occurrence: 1),
        ColumnIdentity(segments: ["b", "c"], occurrence: 0),
        ColumnIdentity(segments: ["b", "c"], occurrence: 1),
      ])
    XCTAssertEqual(loaded.rows, [["1", "2", "3", "4"]])
  }

  /// Catches an object keyed by data that explodes into columns. 65 members make a map, which is
  /// one expandable cell, and 64 members still flatten. The cell opens as a key and value table.
  func testAMapKeyedByDataBecomesOneExpandableCell() throws {
    func object(_ count: Int) -> String {
      "{" + (0..<count).map { "\"k\($0)\":\($0)" }.joined(separator: ",") + "}"
    }

    let flat = try load("[{\"id\":1,\"m\":\(object(64))}]")
    XCTAssertEqual(flat.snapshot.columns.count, 65)

    let loaded = try load("[{\"id\":1,\"m\":\(object(65))}]")

    XCTAssertEqual(loaded.titles, ["id", "m"])
    XCTAssertEqual(loaded.kind(0, "m"), .nested)

    let cell = String(decoding: loaded.snapshot.cell(row: 0, column: 1), as: UTF8.self)
    let opened = loadEmbedded(cell)

    XCTAssertEqual(opened.titles, ["key", "value"])
    XCTAssertEqual(opened.snapshot.rowCount, 65)
    XCTAssertEqual(opened.rows.first, ["k0", "0"])
    XCTAssertEqual(opened.rows.last, ["k64", "64"])
  }

  /// Catches nesting past the flattened paths vanishing. Objects flatten to six key segments, and
  /// what lies below is one expandable cell that opens as a table.
  func testNestingPastTheFlattenedPathsOpensAsANestedTable() throws {
    let loaded = try load(#"[{"a":{"b":{"c":{"d":{"e":{"f":{"g":1}}}}}}}]"#)

    XCTAssertEqual(loaded.titles, ["a.b.c.d.e.f"])
    XCTAssertEqual(loaded.kind(0, "a.b.c.d.e.f"), .nested)
    XCTAssertEqual(loaded.text(0, "a.b.c.d.e.f"), #"{"g":1}"#)

    let opened = loadEmbedded(#"{"g":1}"#)
    XCTAssertEqual(opened.rows, [["g", "1"]])
  }

  /// Catches an array cell that cannot be opened. An array of objects opens as a table with a
  /// column for each key, an array of arrays opens by position, and an empty object is a cell.
  func testAnArrayCellOpensAsATableOfItsOwn() throws {
    let opened = loadEmbedded(#"[{"x":1,"y":{"z":2}},{"x":3,"e":{}}]"#)

    XCTAssertEqual(opened.titles, ["x", "y.z", "e"])
    XCTAssertEqual(opened.text(1, "e"), "{}")
    XCTAssertEqual(opened.kind(1, "e"), .nested)
    XCTAssertEqual(opened.kind(1, "y.z"), .missing)

    XCTAssertEqual(loadEmbedded("[[1,2],[3]]").rows, [["1", "2"], ["3", ""]])
  }

  /// Catches a table without a bound on its width. A row of 1,200 keys fills 1,000 columns and
  /// one last column that holds the rest as an object, so no value is lost.
  func testKeysPastTheColumnCapFoldIntoOneCell() throws {
    let object = "{" + (0..<1_200).map { "\"k\($0)\":\($0)" }.joined(separator: ",") + "}"
    let loaded = try load("[\(object)]")

    XCTAssertEqual(loaded.snapshot.columns.count, JSONRule.maxColumns + 1)
    XCTAssertEqual(loaded.snapshot.columns.last?.identity, JSONColumns.overflowIdentity)
    XCTAssertEqual(loaded.titles.last, "(more keys)")

    let last = loaded.snapshot.columns.count - 1
    let folded = String(decoding: loaded.snapshot.cell(row: 0, column: last), as: UTF8.self)

    XCTAssertEqual(loaded.snapshot.kind(row: 0, column: last), .nested)
    XCTAssertTrue(folded.hasPrefix(#"{"k1000":1000,"#), folded)
    XCTAssertTrue(folded.hasSuffix(#""k1199":1199}"#), folded)
  }

  /// Catches a duplicate-key flood that costs quadratic time. Past the column cap every repeat of
  /// a key used to walk all its occurrences, so a megabyte of repeats ran for a minute and a
  /// cancel could not interrupt it. A repeat must cost the same however many came before.
  func testADuplicateKeyFloodRunsInLinearTime() throws {
    let element = "{" + [String](repeating: "\"a\":1", count: 200_000).joined(separator: ",") + "}"
    let file = try Scratch(self).write("flood.json", "[\(element)]")

    let started = ContinuousClock.now
    let loaded = loadFile(file)
    let elapsed = ContinuousClock.now - started

    XCTAssertEqual(loaded.end, .completed)
    XCTAssertEqual(loaded.snapshot.rowCount, 1)
    XCTAssertEqual(loaded.snapshot.columns.count, JSONRule.maxColumns + 1)
    XCTAssertLessThan(elapsed, .seconds(5), "\(elapsed)")
  }

  /// Catches an element that builds a cell for every scalar before anything is charged. A row
  /// keeps at most `maxCellsPerRow` cells, and a row that lost some is counted.
  func testAWideElementIsBoundedAndCounted() throws {
    let element = "{" + (0..<70_000).map { "\"k\($0)\":1" }.joined(separator: ",") + "}"
    let loaded = try load("[\(element)]")

    XCTAssertEqual(loaded.end, .completed)
    XCTAssertEqual(loaded.progress.truncatedRows, 1)
    XCTAssertEqual(loaded.snapshot.columns.count, JSONRule.maxColumns + 1)
  }

  /// Catches positions lost in the overflow cell. Cells of an array of arrays past the column cap
  /// are titled by position, as the positional columns are.
  func testPositionalCellsPastTheColumnCapKeepTheirPosition() throws {
    let row = "[" + (0..<1_100).map(String.init).joined(separator: ",") + "]"
    let loaded = try load("[\(row)]")
    let last = loaded.snapshot.columns.count - 1
    let folded = String(decoding: loaded.snapshot.cell(row: 0, column: last), as: UTF8.self)

    XCTAssertTrue(folded.hasPrefix(#"{"Column 1001":1000,"#), folded)
    XCTAssertTrue(folded.hasSuffix(#""Column 1100":1099}"#), folded)
  }

  /// Catches a number longer than the cap failing the whole load, when a long string is cut and
  /// counted. The number becomes the note and is counted, and the rest of the file loads.
  func testANumberPastTheCapIsReplacedByANote() throws {
    let huge = String(repeating: "9", count: JSONScanner.maxNumberBytes + 5)
    let loaded = try load("[\(huge),2]")

    XCTAssertEqual(loaded.end, .completed)
    XCTAssertEqual(loaded.rows, [[JSONRule.tooLargeNote], ["2"]])
    XCTAssertEqual(loaded.progress.truncatedRows, 1)
  }

  /// Catches the JSON Lines sniff missing a second value that the sample ends inside. `1` then
  /// `2` is two rows, and the sniff must see the `2` without a byte after it.
  func testAScalarOnlyLinesFileNamedJSONIsLines() throws {
    let loaded = try load("1\n2")

    XCTAssertEqual(loaded.end, .completed)
    XCTAssertEqual(loaded.rows, [["1"], ["2"]])
  }

  // MARK: Shapes

  /// Catches a top-level shape that does not open. An array of scalars has one column, an array of
  /// arrays has a column for each position, and a single object has a key and a value column.
  func testEveryTopLevelShapeOpensAsATable() throws {
    let scalars = try load(#"[1,"x",true,null]"#)
    XCTAssertEqual(scalars.titles, ["value"])
    XCTAssertEqual(scalars.rows, [["1"], ["x"], ["true"], ["null"]])
    XCTAssertEqual(
      (0..<4).map { scalars.snapshot.kind(row: $0, column: 0) }, [.number, .string, .bool, .null])

    let arrays = try load("[[1,2],[3]]")
    XCTAssertEqual(arrays.titles, ["Column 1", "Column 2"])
    XCTAssertEqual(arrays.rows, [["1", "2"], ["3", ""]])
    XCTAssertEqual(arrays.snapshot.kind(row: 1, column: 1), .missing)

    let object = try load(#"{"name":"x","tags":[1],"o":{"k":1}}"#)
    XCTAssertEqual(object.titles, ["key", "value"])
    XCTAssertEqual(object.rows, [["name", "x"], ["tags", "[1]"], ["o", #"{"k":1}"#]])
    XCTAssertEqual(object.kind(1, "value"), .nested)
  }

  /// Catches JSON Lines mistaken for a single value, and the reverse. The extension decides for
  /// `.jsonl`, and the first 64 KiB decides for any other name.
  func testJSONLinesIsToldApartFromASingleValue() throws {
    let lines = try load("{\"a\":1}\n{\"a\":2}\n")
    XCTAssertEqual(lines.end, .completed)
    XCTAssertEqual(lines.rows, [["1"], ["2"]])

    let pretty = try load("[\n  {\"a\": 1},\n  {\"a\": 2}\n]\n")
    XCTAssertEqual(pretty.rows, [["1"], ["2"]])

    let arrayLines = try load("[1,2]\n[3,4]\n")
    XCTAssertEqual(arrayLines.rows, [["1", "2"], ["3", "4"]])

    let byName = try load("[1,2]\n", name: "a.jsonl")
    XCTAssertEqual(byName.rows, [["1", "2"]])

    let scalars = try load("1\n\"two\"\n", name: "a.ndjson")
    XCTAssertEqual(scalars.titles, ["value"])
    XCTAssertEqual(scalars.rows, [["1"], ["two"]])

    let oneLine = try load("{\"a\":1} {\"a\":2}\n", name: "a.jsonl")
    XCTAssertNotNil(invalid(oneLine.end))
  }

  /// Catches a second value read as a row when the first value is too long to sniff. A value
  /// that spans the sample is one value, so what follows it is an error that says so.
  func testAValueLongerThanTheSampleIsOneValue() throws {
    let numbers = (0..<20_000).map(String.init).joined(separator: ",")
    let loaded = try load("[\(numbers)]\n5\n")

    XCTAssertGreaterThan(numbers.utf8.count, JSONRule.sampleSize)
    XCTAssertEqual(invalid(loaded.end)?.reason, "unexpected data after the JSON value")
    XCTAssertEqual(invalid(loaded.end)?.line, 2)
  }

  /// Catches a scalar or an empty file that crashes or shows a blank table. A scalar says what it
  /// holds, and an empty array or an empty file loads with no rows.
  func testAScalarOrAnEmptyArrayOpensWithAMessage() throws {
    let scalar = try load("42")
    XCTAssertEqual(
      scalar.end, .failed(.notATable(path: scalar.end.failedPath ?? "", what: "a number")))
    XCTAssertTrue(
      try XCTUnwrap(scalar.end.failureText).contains("holds only a number"), "\(scalar.end)")

    let empty = try load("[]")
    XCTAssertEqual(empty.end, .completed)
    XCTAssertTrue(empty.snapshot.columns.isEmpty)
    XCTAssertEqual(empty.snapshot.rowCount, 0)

    XCTAssertEqual(try load("  \n").end, .completed)
    XCTAssertEqual(try load("{}").snapshot.rowCount, 0)
  }

  // MARK: Failures

  /// Catches input that nests deeply enough to crash a recursive reader. Past the cap the load
  /// ends with a message, and a value nested below an element's columns still opens.
  func testDeeplyNestedInputShowsAnErrorInsteadOfCrashing() throws {
    let tooDeep = try load(String(repeating: "[", count: 300) + String(repeating: "]", count: 300))
    XCTAssertEqual(invalid(tooDeep.end)?.reason, "nested more than 256 levels deep")

    let hostile = try load(String(repeating: "{\"a\":", count: 100_000))
    XCTAssertNotNil(invalid(hostile.end))

    let nested = "[" + String(repeating: "[", count: 200) + String(repeating: "]", count: 200) + "]"
    let loaded = try load(nested)
    XCTAssertEqual(loaded.end, .completed)
    XCTAssertEqual(loaded.kind(0, "Column 1"), .nested)

    let cell = String(decoding: loaded.snapshot.cell(row: 0, column: 0), as: UTF8.self)
    XCTAssertEqual(loadEmbedded(cell).end, .completed)
  }

  /// Catches a syntax error that loads as a partial table, or says nothing about where it is.
  func testSyntaxErrorsEndTheLoadAndNameTheLine() throws {
    let cases = [
      "[1,]", #"{"a" 1}"#, "[1 2]", "{'a':1}", "[01]", #"["a\x"]"#, "[tru]", "[1,2", "[1.]",
      "[\"a\nb\"]", "[\u{1}]", "[1] x", "}", #"["\u12"]"#,
    ]

    for text in cases {
      let loaded = try load(text)

      XCTAssertNotNil(invalid(loaded.end), "\(text) loaded as \(loaded.end)")
      XCTAssertEqual(loaded.snapshot.rowCount, 0, text)
    }

    XCTAssertEqual(invalid(try load("[\n1,\n,]").end)?.line, 3)
  }

  // MARK: Strings

  /// Catches an escape that decodes wrongly. A surrogate pair joins into one character, a lone
  /// surrogate becomes U+FFFD, and the other escapes give their characters.
  func testStringEscapesDecodeToUTF8() throws {
    let loaded = try load(#"["aé😀\ud800x\n\t\"\\\/", "\udc00"]"#)

    XCTAssertEqual(loaded.snapshot.text(row: 0, column: 0), "a\u{E9}\u{1F600}\u{FFFD}x\n\t\"\\/")
    XCTAssertEqual(loaded.snapshot.text(row: 1, column: 0), "\u{FFFD}")
  }

  /// Catches a string that is not capped. A string keeps the cell cap and the row is counted.
  func testAnOversizedStringIsCutAndCounted() throws {
    let loaded = try load(
      "[\"" + String(repeating: "x", count: JSONRule.maxStringBytes + 10) + "\",\"y\"]")

    XCTAssertEqual(loaded.snapshot.cell(row: 0, column: 0).count, JSONRule.maxStringBytes)
    XCTAssertEqual(loaded.progress.truncatedRows, 1)
    XCTAssertEqual(loaded.snapshot.text(row: 1, column: 0), "y")
  }

  // MARK: Streaming

  /// Catches a reader that parses the whole document before it shows a row. Under a budget that
  /// holds only a few rows, the load stops after the first chunk of a file five times that size, so
  /// the rest was never read.
  func testALargeArrayStreamsUnderTheBudgetWithoutReadingTheWholeFile() throws {
    var text = "["

    for index in 0..<60_000 {
      text += (index > 0 ? "," : "") + "{\"id\":\(index),\"name\":\"row-\(index)\"}"
    }

    text += "]"

    let file = try Scratch(self).write("big.json", text)
    let loaded = loadFile(file, budget: TableBudget(limit: 8_000, floor: 0), pageTarget: 1_000)

    XCTAssertGreaterThan(text.utf8.count, 1_000_000)
    XCTAssertEqual(loaded.end, .stoppedAtBudget)
    XCTAssertGreaterThan(loaded.snapshot.rowCount, 0)
    XCTAssertLessThan(loaded.snapshot.rowCount, 1_000)
    XCTAssertLessThan(loaded.progress.bytesRead, loaded.progress.totalBytes / 2)

    for row in 0..<loaded.snapshot.rowCount {
      XCTAssertEqual(loaded.snapshot.text(row: row, column: 0), "\(row)")
    }

    let whole = loadFile(file)
    XCTAssertEqual(whole.end, .completed)
    XCTAssertEqual(whole.snapshot.rowCount, 60_000)
    XCTAssertEqual(whole.snapshot.text(row: 59_999, column: 1), "row-59999")
  }

  /// Catches a UTF-16 file with a byte-order mark failing, and a UTF-8 mark reaching the scanner as
  /// an unexpected character.
  func testByteOrderMarksAreSkippedAndUTF16Converts() throws {
    let scratch = try Scratch(self)
    let text = #"[{"k":"caf\#u{E9}"}]"#

    let utf8 = try scratch.write("bom.json", [0xEF, 0xBB, 0xBF] + Array(text.utf8))
    let utf16 = try scratch.write(
      "le.json", [0xFF, 0xFE] + text.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })

    for file in [utf8, utf16] {
      XCTAssertEqual(loadFile(file).rows, [["caf\u{E9}"]], file.lastPathComponent)
    }
  }

  // MARK: Sort order

  /// Catches a mixed column that sorts in no defined order. Ascending is numbers, text, booleans,
  /// nested cells, null, and missing. Descending reverses the first four and keeps null and missing
  /// last. A string that looks like a number sorts as text.
  func testASortOverMixedTypesFollowsOneDefinedOrder() throws {
    let loaded = try load(
      """
      [{"v":3},{"v":"b"},{"v":true},{"v":null},{"v":[1]},{"w":0},{"v":"A"},{"v":1.5},
       {"v":false},{"v":"12"},{"v":10}]
      """)

    let column = loaded.snapshot.columns.firstIndex { $0.title == "v" } ?? 0

    func sorted(ascending: Bool) -> [String] {
      let query = TableQuery(
        sort: SortSpec(column: loaded.snapshot.columns[column].identity, ascending: ascending))

      guard let selection = TableQueryEngine.evaluate(loaded.snapshot, query: query) else {
        return []
      }

      return (0..<selection.count).map {
        let row = selection.row(at: $0)
        let kind = loaded.snapshot.kind(row: row, column: column)

        return kind == .missing ? "missing" : loaded.snapshot.text(row: row, column: column)
      }
    }

    XCTAssertEqual(
      sorted(ascending: true),
      ["1.5", "3", "10", "12", "A", "b", "false", "true", "[1]", "null", "missing"])
    XCTAssertEqual(
      sorted(ascending: false),
      ["[1]", "true", "false", "b", "A", "12", "10", "3", "1.5", "null", "missing"])
  }

  // MARK: Embedded values

  /// Catches a nested load that reports a failure for a value the file load already checked.
  func testAnEmbeddedValueLoadsThroughTheSameReader() {
    let loaded = loadEmbedded(#"{"a":[1,2],"b":{"c":null}}"#)

    XCTAssertEqual(loaded.end, .completed)
    XCTAssertEqual(loaded.rows, [["a", "[1,2]"], ["b", #"{"c":null}"#]])
  }
}

extension LoadEnd {
  fileprivate var failedPath: String? {
    guard case .failed(.notATable(let path, _)) = self else { return nil }

    return path
  }

  fileprivate var failureText: String? {
    guard case .failed(let error) = self else { return nil }

    return error.errorDescription
  }
}
