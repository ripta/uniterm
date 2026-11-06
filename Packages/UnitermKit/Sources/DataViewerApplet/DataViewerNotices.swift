import Foundation

/// The notice lines that the table pane and a nested table share.
enum DataViewerNotices {
  static func lines(sortSkipped: Bool, truncatedRows: Int) -> [String] {
    var lines: [String] = []

    if sortSkipped {
      lines.append("There is not enough memory to sort this many rows, so they show in file order.")
    }

    if truncatedRows > 0 {
      lines.append(
        truncatedRows == 1
          ? "1 row had an oversized cell cut."
          : "\(truncatedRows.formatted()) rows had oversized cells cut.")
    }

    return lines
  }
}
