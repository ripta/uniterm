import AppletKit
import Foundation

/// The notices that the table pane and a nested table share. Rows left in file order or cut to
/// size are content changed on screen, so they are warnings.
enum DataViewerNotices {
  /// The identity of the cut-rows notice. Its count grows while a load runs, so the text cannot
  /// be its identity.
  static let cutRowsKey = "cut-rows"

  /// The identity of the notice that sorting was skipped. A restored sort and a sort the user
  /// makes later are both this notice, so the applet tells them apart by origin.
  static let sortSkippedKey = "sort-skipped"

  /// The notices for a table. The count of cut rows is final only once the load has settled, so
  /// the cut-rows notice waits for that. It then posts once, with the whole count. A segment
  /// shows the count while the load runs.
  static func notices(sortSkipped: Bool, truncatedRows: Int, settled: Bool) -> [AppletNotice] {
    var notices: [AppletNotice] = []

    if sortSkipped {
      notices.append(
        AppletNotice(
          .warning,
          "There is not enough memory to sort this many rows, so they show in file order.",
          key: sortSkippedKey))
    }

    if truncatedRows > 0, settled {
      let text =
        truncatedRows == 1
        ? "1 row had an oversized cell cut."
        : "\(truncatedRows.formatted()) rows had oversized cells cut."

      notices.append(AppletNotice(.warning, text, key: cutRowsKey))
    }

    return notices
  }
}
