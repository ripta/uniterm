import AppKit
import TableData

/// How wide a column starts: wide enough for its header and for the widest value in a sample of
/// the rows loaded so far, within fixed bounds.
///
/// The sample is the first `sampleRows` rows of the file, and each value is measured to at most
/// `sampleCharacters` characters. So the cost of a column is bounded however large the file is. A
/// value wider than `maximum` is cut in the cell, and its popover shows it whole.
enum ColumnWidth {
  static let minimum: CGFloat = 48
  static let maximum: CGFloat = 320
  static let sampleRows = 50
  static let sampleCharacters = 120

  /// Room for the label's insets and the text field's own margin.
  static let cellPadding: CGFloat = 12

  /// Room for the header's margins and the sort indicator.
  static let headerPadding: CGFloat = 24

  /// The text a cell of the given kind shows, as `DataViewerView` draws it.
  static func displayText(_ snapshot: TableSnapshot, row: Int, column: Int, limit: Int) -> String {
    switch snapshot.kind(row: row, column: column) {
    case .nested: return "\u{25B8} " + snapshot.text(row: row, column: column, limit: limit)
    case .null: return "null"
    case .notComputed: return "not computed"
    default: return snapshot.text(row: row, column: column, limit: limit)
    }
  }

  /// The width for a column, from its title and the sampled rows of `snapshot`.
  ///
  /// The caller measures cells in the tabular-digit font. Whether a column is numeric is decided
  /// later, and that font is never narrower than the plain one, so a number never gets cut.
  static func fitted(
    title: String, column: Int, in snapshot: TableSnapshot, headerFont: NSFont, cellFont: NSFont
  ) -> CGFloat {
    var widest = width(of: title, font: headerFont) + headerPadding

    for row in 0..<min(snapshot.rowCount, sampleRows) {
      let text = displayText(snapshot, row: row, column: column, limit: sampleCharacters * 4)

      widest = max(
        widest, width(of: String(text.prefix(sampleCharacters)), font: cellFont) + cellPadding)

      if widest >= maximum { break }
    }

    return min(maximum, max(minimum, widest.rounded(.up)))
  }

  private static func width(of text: String, font: NSFont) -> CGFloat {
    guard !text.isEmpty else { return 0 }

    return (text as NSString).size(withAttributes: [.font: font]).width
  }
}
