import Foundation

/// One row of a sheet, as the reader hands it on.
struct SheetRow {
  /// The cells the row holds, sorted by column with no column twice.
  var cells: [TypedCell]

  /// True when every cell is a text label, which is what a header row looks like.
  var allLabels: Bool

  /// True when a cap cut a cell, dropped cells, or ended the row early.
  var wasCut: Bool
}

/// Reads `<sheetData>` row by row. It keeps one row at a time, whatever the size of the sheet.
///
/// A cell lands in the column its reference names, so a row that skips cells keeps the rest in
/// place. A cell with no reference follows the one before it. Nothing is evaluated: a formula shows
/// its cached result, and one that has none shows as not computed. A row with no cells that hold
/// anything is dropped.
///
/// Numbers keep the text the file stores. A number in a date style shows as a date, under the date
/// system the workbook names. Other formats, such as a percent or a currency, show the stored
/// number.
final class SheetHandler: XMLHandler {
  /// Gets each finished row. Returns false to stop the read.
  var onRow: ((SheetRow) -> Bool)?

  private enum Collecting {
    case none
    case value
    case inline
  }

  private let strings: SharedStrings
  private let styles: [NumberStyle]
  private let date1904: Bool
  private let limits: SpreadsheetLimits

  private var cells: [TypedCell] = []
  private var rowBytes = 0
  private var rowIsCut = false
  private var allLabels = true
  private var isSorted = true
  private var nextColumn = 0

  private var column: Int?
  private var style = 0
  private var type: String?
  private var hasFormula = false
  private var hasValue = false
  private var value: [UInt8] = []
  private var inline: [UInt8] = []
  private var cellIsCut = false
  private var inInline = false
  private var phonetic = 0
  private var collecting = Collecting.none

  init(
    strings: SharedStrings, styles: [NumberStyle], date1904: Bool, limits: SpreadsheetLimits
  ) {
    self.strings = strings
    self.styles = styles
    self.date1904 = date1904
    self.limits = limits
  }

  override func begin(_ name: String, _ attributes: [String: String]) {
    switch name {
    case "row":
      cells.removeAll(keepingCapacity: true)
      rowBytes = 0
      rowIsCut = false
      allLabels = true
      isSorted = true
      nextColumn = 0

    case "c":
      startCell(attributes)

    case "v":
      hasValue = true
      value.removeAll(keepingCapacity: true)
      collecting = .value

    case "f":
      hasFormula = true

    case "is":
      inInline = true
      inline.removeAll(keepingCapacity: true)

    case "rPh":
      phonetic += 1

    case "t" where inInline && phonetic == 0:
      collecting = .inline

    default:
      break
    }
  }

  override func end(_ name: String) {
    switch name {
    case "v", "t":
      collecting = .none

    case "is":
      inInline = false

    case "rPh":
      phonetic = max(0, phonetic - 1)

    case "c":
      finishCell()

    case "row":
      finishRow()

    default:
      break
    }
  }

  override func text(_ characters: String) {
    switch collecting {
    case .none:
      break

    case .value:
      if SpreadsheetText.append(characters, to: &value, cap: limits.cellBytes) {
        cellIsCut = true
      }

    case .inline:
      if SpreadsheetText.append(characters, to: &inline, cap: limits.cellBytes) {
        cellIsCut = true
      }
    }
  }

  // MARK: Cells

  private func startCell(_ attributes: [String: String]) {
    style = Int(attributes["s"] ?? "") ?? 0
    type = attributes["t"]
    hasFormula = false
    hasValue = false
    cellIsCut = false
    inInline = false
    phonetic = 0
    collecting = .none
    value.removeAll(keepingCapacity: true)
    inline.removeAll(keepingCapacity: true)

    if let reference = attributes["r"], let parsed = Self.column(of: reference) {
      column = parsed
    } else {
      column = nextColumn
    }
  }

  /// The column a reference such as `AB12` names, counted from zero. A run of more than three letters
  /// names a column past the last, which the caller cuts. Nil when the reference has no letters.
  static func column(of reference: String) -> Int? {
    var value = 0
    var letters = 0

    for byte in reference.utf8 {
      let upper = byte & 0xDF

      guard upper >= 0x41, upper <= 0x5A else { break }

      letters += 1

      guard letters <= 3 else { return SpreadsheetLimits.maxColumns }

      value = value * 26 + Int(upper - 0x40)
    }

    return letters > 0 ? value - 1 : nil
  }

  private func finishCell() {
    defer {
      collecting = .none
      type = nil
    }

    guard let column else { return }

    nextColumn = column + 1

    guard let (kind, bytes, isLabel) = resolved() else { return }

    if cellIsCut { rowIsCut = true }

    guard column < SpreadsheetLimits.maxColumns, cells.count < limits.rowCells,
      rowBytes + bytes.count <= limits.rowBytes
    else {
      rowIsCut = true
      return
    }

    rowBytes += bytes.count

    if let last = cells.last, last.column >= column { isSorted = false }

    if !isLabel { allLabels = false }

    cells.append(TypedCell(column: column, kind: kind, bytes: bytes))
  }

  /// The kind, text, and label flag of the finished cell. Nil for a cell that holds nothing.
  private func resolved() -> (CellKind, [UInt8], Bool)? {
    let kind = type ?? "n"

    if hasFormula, !hasValue || (value.isEmpty && kind != "str") {
      allLabels = false
      return (.notComputed, [], false)
    }

    switch kind {
    case "s":
      let index = Int(String(decoding: value, as: UTF8.self).trimmingCharacters(in: .whitespaces))

      guard let index, let text = strings.string(at: index), !text.isEmpty else { return nil }

      return (.string, Array(text), true)

    case "str":
      let text = SpreadsheetText.unescape(value)
      return text.isEmpty ? nil : (.string, text, true)

    case "inlineStr":
      let text = SpreadsheetText.unescape(inline)
      return text.isEmpty ? nil : (.string, text, true)

    case "b":
      let on = String(decoding: value, as: UTF8.self).trimmingCharacters(in: .whitespaces)

      guard !on.isEmpty else { return nil }

      return (.bool, Array((on == "1" || on == "true" ? "true" : "false").utf8), false)

    case "e", "d":
      return value.isEmpty ? nil : (.string, value, false)

    default:
      let text = String(decoding: value, as: UTF8.self).trimmingCharacters(in: .whitespaces)

      guard !text.isEmpty else { return nil }

      guard let number = Double(text) else { return (.string, Array(text.utf8), false) }

      if style >= 0, style < styles.count, styles[style] != .plain,
        let formatted = SpreadsheetDates.format(number, style: styles[style], date1904: date1904)
      {
        return (.string, Array(formatted.utf8), false)
      }

      return (.number, Array(text.utf8), false)
    }
  }

  private func finishRow() {
    guard !cells.isEmpty else { return }

    if !isSorted {
      // The last cell for a column wins, as in a spreadsheet that applies cells in file order.
      var latest: [Int: TypedCell] = [:]

      for cell in cells { latest[cell.column] = cell }

      cells = latest.values.sorted { $0.column < $1.column }
    }

    let row = SheetRow(cells: cells, allLabels: allLabels, wasCut: rowIsCut)

    if onRow?(row) == false { stop(.cancelled) }
  }
}
