import Foundation

/// The rules that turn JSON into a table, in one place so the same file always gives the same
/// table. The reader streams: it never parses a whole document first.
///
/// Shapes, by what the file holds:
/// 1. An array opens one row for each element, so the rows stream as the array is read.
/// 2. An array of objects has a column for each key path. The columns are the union over all rows, in
///    the order they were first seen.
/// 3. An array of scalars has one column, `value`.
/// 4. An array of arrays has a column for each position.
/// 5. A single object has two columns, `key` and `value`, and a row for each member.
/// 6. JSON Lines is read as the array of its values. See "JSON Lines" below.
/// 7. A scalar on its own is not a table, and the pane says so. An empty array is a table with no
///    rows, and the pane says that.
/// 8. A mix works. An element that is an object, a scalar, or an array fills its own columns.
///
/// Nested values:
/// 1. An object inside an object becomes columns named by its path. A column's identity is the
///    list of key segments, never a dotted string. So `{"a.b":1,"a":{"b":2}}` has two columns, and
///    the title of the first escapes the dot as `a\.b`.
/// 2. An array, and an object past `maxFlattenDepth` keys deep, becomes one expandable cell. The cell
///    holds the value's compact JSON text, and opening it shows the value as a table of its own.
/// 3. A key that holds an object in some rows and a scalar or an array in others keeps every value.
///    The path column holds the scalars, and the flattened columns hold the object's members.
/// 4. A nested object with more than `maxMapMembers` members is a map keyed by data, such as IDs
///    as keys. It becomes one expandable cell in place of that many columns.
/// 5. An empty object or array is an expandable cell that shows `{}` or `[]`.
/// 6. A row keeps at most `maxCellsPerRow` cells. A table holds at most `maxColumns` columns. Keys past that go into one last column, `(more
///    keys)`, as an expandable cell holding an object of them, so no value is lost.
///
/// Missing and null: a row that lacks a key has no cell there, and shows blank. A key set to
/// `null` shows `null`.
///
/// Numbers keep their original text. A large integer or a long decimal is never rounded.
/// A sort compares the value as a double, so integers past 2^53 that differ only in their
/// last digits keep file order.
///
/// Duplicate keys: every value is kept. The first time a key path appears in a row it fills the
/// path's first column. The second time fills a second column with the same path, and so on. This is
/// the column occurrence that `ColumnIdentity` already models for repeated CSV headers.
///
/// JSON Lines versus a single value:
/// 1. A name ending in `.jsonl` or `.ndjson` is JSON Lines.
/// 2. Any other name is JSON Lines when the first 64 KiB holds a whole first value and a second
///    value after it. Otherwise the file is one value. A value that spans more than that sample
///    is one value, and anything after it is an error, not a second row.
/// 3. In JSON Lines each value starts on its own line, and each is a row by the shapes above. A
///    top-level scalar is a row of the `value` column.
///
/// Encoding is UTF-8. A byte-order mark is skipped, and UTF-16 with a byte-order mark is
/// converted. Syntax is strict RFC 8259. See `JSONScanner`. A syntax error or nesting past
/// `JSONScanner.maxDepth` ends the load with a message that names the line, and no rows are shown.
///
/// Mixed-type sort order is documented with the sort in `TableQueryEngine`.
enum JSONRule {
  /// A string value keeps this many bytes. A cell that is a nested value too large for it shows a
  /// note in its place.
  static let maxStringBytes = CSVParser.maxCellBytes

  /// One array element or object member is held whole while it is flattened, up to this size.
  static let maxElementBytes = CSVParser.maxRowBytes

  /// A row keeps at most this many cells. The rest are dropped, and the row is counted as cut. A
  /// hostile element then cannot build millions of cells before the budget sees any of them.
  static let maxCellsPerRow = 65_536

  static let maxMapMembers = 64
  static let maxFlattenDepth = 6
  static let maxColumns = 1000

  static let sampleSize = CSVRule.sampleSize

  static let tooLargeNote = "(value too large to show)"

  /// The title a path column shows. A dot or a backslash inside a key is escaped, so the title
  /// reads back as the same segments.
  static func title(of segments: [String]) -> String {
    segments.map { segment in
      segment.isEmpty
        ? "\"\""
        : segment.replacingOccurrences(of: "\\", with: "\\\\")
          .replacingOccurrences(of: ".", with: "\\.")
    }.joined(separator: ".")
  }

  /// Whether a file is JSON Lines. `sample` is the file's first bytes as UTF-8 text.
  static func isLines(fileExtension: String, sample: ArraySlice<UInt8>) -> Bool {
    if ["jsonl", "ndjson"].contains(fileExtension.lowercased()) { return true }

    var scanner = JSONScanner(mode: .lines)
    var second = false

    let sink: (JSONEvent, JSONContext) -> Bool = { _, context in
      if context.valueCount >= 1 {
        second = true
        return false
      }

      return true
    }

    // A sample that ends inside the second value's number or word has no event until the input
    // ends, so the sniff ends it. An open container is only a sample cut short, and fails quietly.
    _ = try? scanner.feed(sample, sink: sink)
    try? scanner.finish(sink: sink)

    return second
  }
}
