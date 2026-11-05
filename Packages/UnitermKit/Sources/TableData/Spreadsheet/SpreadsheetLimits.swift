import Foundation

/// The caps that keep a hostile workbook from using the machine. Every cap counts bytes that were
/// actually inflated or stored, never a size the archive claims.
struct SpreadsheetLimits: Sendable {
  /// Inflated bytes of one small part, such as the workbook, its relationships, or the styles.
  var metadataBytes = 32 << 20

  /// Inflated bytes of the shared strings table. Its text stays in memory for the whole load, so it
  /// has a cap of its own.
  var sharedStringBytes = 64 << 20

  /// Inflated bytes of the sheet being read. Rows stream, so this bounds time, not memory.
  var sheetBytes = 4 << 30

  /// Entries in the archive.
  var entries = 100_000

  /// Nesting of XML elements. A worksheet nests about eight deep.
  var depth = 64

  /// Bytes of one cell's text. The rest is cut.
  var cellBytes = 1 << 20

  /// Bytes and cells that one row keeps. The rest is cut.
  var rowBytes = 16 << 20
  var rowCells = 65_536

  /// Sheets and relationships a workbook may name.
  var sheets = 10_000
  var relationships = 100_000

  /// Cell styles the styles part may define.
  var styles = 1 << 20

  /// Called with the size of each chunk the reader hands to the XML parser. Tests use it to show
  /// that no part is ever held whole.
  var observeChunk: (@Sendable (Int) -> Void)?

  static let standard = SpreadsheetLimits()

  /// The widest sheet. Excel stops at column XFD.
  static let maxColumns = 16_384
}

/// Why a workbook did not read. The loader turns each into a `TableLoadError`.
enum SpreadsheetFailure: Error, Equatable {
  case tooLarge(String)
  case invalid(String)
  case unsupported(UnsupportedSpreadsheet)
  case cancelled

  /// The parser stopped listening, so the producer's write failed. Never shown.
  case consumerGone

  /// The memory budget refused a reservation. This says nothing about the file, so it ends the load
  /// like any other budget stop and never reads as a hostile workbook.
  case refused(TableBudget.Reservation)
}
