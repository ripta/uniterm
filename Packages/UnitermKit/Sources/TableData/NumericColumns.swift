import Foundation

/// Finds the columns that hold numbers, so a view can right-align them.
///
/// A column is numeric when it holds at least one number and every other cell in it is empty. A
/// JSON or spreadsheet cell says what it is: a number counts, and null, missing, and a formula
/// with no cached result count as empty. A CSV cell has no kind, so it passes the same number test
/// the sort uses, and an empty CSV cell is empty. Anything else, such as text, a boolean, a
/// nested value, or a spreadsheet date, makes the column not numeric.
///
/// The scan reads every loaded row. `TableSession` runs it off the main thread after the first
/// rows arrive and again when the load ends, so a column that turns out to hold text further down
/// is caught by the end of the load.
public enum NumericColumns {
  /// Nil when `isCancelled` turned true before the scan was done.
  public static func find(in snapshot: TableSnapshot, isCancelled: () -> Bool = { false })
    -> IndexSet?
  {
    var candidates = IndexSet(integersIn: 0..<snapshot.columns.count)
    var seen = IndexSet()
    var counter = 0
    var cancelled = false

    snapshot.forEachRow { row, page, local in
      counter += 1

      if counter & 0xFF == 0, isCancelled() {
        cancelled = true
        return false
      }

      for column in candidates {
        switch page.kind(row: local, column: column) {
        case .missing, .null, .notComputed:
          continue

        case .number:
          seen.insert(column)

        case .text:
          let text = snapshot.text(row: row, column: column, limit: 512)

          if text.isEmpty { continue }

          if CSVRule.number(text) != nil {
            seen.insert(column)
          } else {
            candidates.remove(column)
          }

        case .bool, .string, .nested:
          candidates.remove(column)
        }
      }

      return !candidates.isEmpty
    }

    return cancelled ? nil : candidates.intersection(seen)
  }
}
