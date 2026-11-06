import Foundation

/// The cells a find query matched, in reading order: row by row, then column by column.
///
/// A row is a position among the rows the query shows, so it is the row the table displays and not
/// a row of the file. A match set belongs to the selection it ran on. A new selection needs a new
/// search.
public struct SearchMatches: Sendable, Equatable {
  public static let none = SearchMatches(keys: [], isTruncated: false)

  /// The row in the high half and the column in the low half, so the order of the numbers is the
  /// reading order.
  private let keys: [UInt64]

  /// True when the search stopped at its limit, so later cells may match too.
  public let isTruncated: Bool

  init(keys: [UInt64], isTruncated: Bool) {
    self.keys = keys
    self.isTruncated = isTruncated
  }

  public var count: Int { keys.count }

  public var isEmpty: Bool { keys.isEmpty }

  public func position(at index: Int) -> (row: Int, column: Int) {
    let key = keys[index]

    return (Int(key >> 32), Int(key & 0xFFFF_FFFF))
  }

  public func contains(row: Int, column: Int) -> Bool {
    let key = Self.key(row: row, column: column)
    let index = firstIndex(atOrAfter: key)

    return index < keys.count && keys[index] == key
  }

  static func key(row: Int, column: Int) -> UInt64 {
    UInt64(row) << 32 | UInt64(column)
  }

  private func firstIndex(atOrAfter key: UInt64) -> Int {
    var low = 0
    var high = keys.count

    while low < high {
      let middle = (low + high) / 2

      if keys[middle] < key {
        low = middle + 1
      } else {
        high = middle
      }
    }

    return low
  }
}

/// Finds a query in the cells of the rows a selection shows.
///
/// A cell matches when it contains the text, ignoring case, the way the filter matches. A nested
/// cell holds its JSON text, so a search finds text inside it too. The search reads the rows the
/// selection shows. So a filtered table is searched within the filter, and a sorted table is
/// searched in the order it shows.
public enum TableSearchEngine {
  /// The most matches one search keeps. A query that matches more than this is not a way to find
  /// anything, and the list would cost memory the budget does not count.
  public static let matchLimit = 1_000_000

  /// Where the current match goes after a search: the match on the cell at the file row and column,
  /// or when that cell no longer matches, the first match after it in the order shown. Zero when
  /// none follows. A row of the file is stable across a filter or a sort, so the place survives
  /// both.
  public static func startIndex(
    in matches: SearchMatches, selection: RowSelection, row: Int, column: Int
  ) -> Int {
    var after: Int?

    for index in 0..<matches.count {
      let place = matches.position(at: index)
      let source = selection.row(at: place.row)

      if source == row, place.column == column { return index }

      if after == nil, source > row || (source == row && place.column > column) {
        after = index
      }
    }

    return after ?? 0
  }

  /// Nil when `isCancelled` turned true before the search was done.
  public static func run(
    _ snapshot: TableSnapshot, selection: RowSelection, query: String,
    limit: Int = matchLimit, isCancelled: () -> Bool = { false }
  ) -> SearchMatches? {
    guard !query.isEmpty else { return SearchMatches.none }

    let matcher = CellMatcher(query)
    let columns = snapshot.columns.count
    var keys: [UInt64] = []

    for index in 0..<selection.count {
      if index & 0x3FF == 0, isCancelled() { return nil }

      let row = selection.row(at: index)

      for column in 0..<columns where matcher.matches(snapshot.cell(row: row, column: column)) {
        if keys.count == limit {
          return SearchMatches(keys: keys, isTruncated: true)
        }

        keys.append(SearchMatches.key(row: index, column: column))
      }
    }

    return isCancelled() ? nil : SearchMatches(keys: keys, isTruncated: false)
  }
}
