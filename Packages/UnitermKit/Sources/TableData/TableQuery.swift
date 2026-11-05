import Foundation

/// A sort by one column.
public struct SortSpec: Equatable, Codable, Sendable {
  public var column: ColumnIdentity
  public var ascending: Bool

  public init(column: ColumnIdentity, ascending: Bool) {
    self.column = column
    self.ascending = ascending
  }
}

/// What the user asked to see: a sort and a filter.
public struct TableQuery: Equatable, Sendable {
  public var sort: SortSpec?

  /// Text that a row must contain in some cell, ignoring case. Empty shows every row.
  public var filter: String

  public init(sort: SortSpec? = nil, filter: String = "") {
    self.sort = sort
    self.filter = filter
  }

  public var isEmpty: Bool { sort == nil && filter.isEmpty }
}

/// The rows a query shows, as row numbers of the snapshot it ran on. Rows only append, so the
/// numbers stay valid for every later snapshot of the same load.
public enum RowSelection: Sendable, Equatable {
  /// Every row, in file order.
  case all(count: Int)

  case rows([UInt32])

  public var count: Int {
    switch self {
    case .all(let count): return count
    case .rows(let rows): return rows.count
    }
  }

  public func row(at index: Int) -> Int {
    switch self {
    case .all: return index
    case .rows(let rows): return Int(rows[index])
    }
  }
}

/// Where a sort gets the memory for its keys. The keys scale with the rows, and the rows already
/// fill the budget, so the sort asks the same budget and gives the bytes back when it is done.
public struct SortMemory: Sendable {
  let reserve: @Sendable (Int) -> Bool
  let giveBack: @Sendable (Int) -> Void

  public init(lease: TableBudget.Lease) {
    reserve = { lease.reserve($0) == .granted }
    giveBack = { lease.giveBack($0) }
  }
}

/// How a query ended.
public enum QueryOutcome: Sendable, Equatable {
  /// The rows to show. `sortSkipped` is true when the sort did not get the memory it needed, so the
  /// rows are filtered and in file order.
  case done(RowSelection, sortSkipped: Bool)

  case cancelled
}

/// Filters and sorts a snapshot.
///
/// The filter keeps a row when some cell contains the text, ignoring case. The sort reads one
/// column. Ascending, cells that are plain numbers sort by value and come before cells that are
/// text. Descending reverses that. Text sorts by its lowercased form, and a cell with nothing in it
/// comes last in either direction. Rows that compare equal keep file order.
public enum TableQueryEngine {
  /// Nil when `isCancelled` turned true before the result was done.
  public static func evaluate(
    _ snapshot: TableSnapshot, query: TableQuery, isCancelled: () -> Bool = { false }
  ) -> RowSelection? {
    guard case .done(let selection, _) = run(snapshot, query: query, isCancelled: isCancelled)
    else { return nil }

    return selection
  }

  public static func run(
    _ snapshot: TableSnapshot, query: TableQuery, isCancelled: () -> Bool = { false },
    memory: SortMemory? = nil
  ) -> QueryOutcome {
    let sortColumn = query.sort.flatMap { spec in
      snapshot.columns.firstIndex { $0.identity == spec.column }
    }

    guard !query.filter.isEmpty || sortColumn != nil else {
      return .done(.all(count: snapshot.rowCount), sortSkipped: false)
    }

    var rows: [UInt32] = []

    if query.filter.isEmpty {
      rows = (0..<UInt32(snapshot.rowCount)).map { $0 }
    } else {
      let matcher = CellMatcher(query.filter)
      var counter = 0

      snapshot.forEachRow { row, page, local in
        counter += 1

        if counter & 0xFFF == 0, isCancelled() { return false }

        let first = Int(page.rowFirstCell[local])

        for cell in 0..<page.cellCount(row: local) {
          let start = first + cell == 0 ? 0 : Int(page.cellEnds[first + cell - 1])

          if matcher.matches(page.bytes[start..<Int(page.cellEnds[first + cell])]) {
            rows.append(UInt32(row))
            break
          }
        }

        return true
      }
    }

    if isCancelled() { return .cancelled }

    var skipped = false

    if let sortColumn, let spec = query.sort {
      switch sort(rows, snapshot: snapshot, column: sortColumn, spec, isCancelled, memory) {
      case .sorted(let sorted):
        rows = sorted

      case .cancelled:
        return .cancelled

      case .noMemory:
        skipped = true
      }
    }

    return isCancelled() ? .cancelled : .done(.rows(rows), sortSkipped: skipped)
  }

  private enum SortResult {
    case sorted([UInt32])
    case cancelled
    case noMemory
  }

  private enum Key {
    case number(Double)
    case text(String)
    case empty
  }

  private static func sort(
    _ rows: [UInt32], snapshot: TableSnapshot, column: Int, _ spec: SortSpec,
    _ isCancelled: () -> Bool, _ memory: SortMemory?
  ) -> SortResult {
    // A key, the order array, its sorted copy, and the result, for each row. Text longer than a
    // small string also holds heap bytes, which are reserved in batches as the keys are built.
    var reserved = 0
    defer { if reserved > 0 { memory?.giveBack(reserved) } }

    let fixed = rows.count * (MemoryLayout<Key>.stride + 2 * MemoryLayout<Int>.stride + 4)

    if let memory {
      guard memory.reserve(fixed) else { return .noMemory }

      reserved += fixed
    }

    var heap = 0
    var keys: [Key] = []
    keys.reserveCapacity(rows.count)

    for (index, row) in rows.enumerated() {
      if index & 0xFFF == 0 {
        if isCancelled() { return .cancelled }

        if let memory, heap > 0 {
          guard memory.reserve(heap) else { return .noMemory }

          reserved += heap
          heap = 0
        }
      }

      let text = snapshot.text(row: Int(row), column: column, limit: 512)
      heap += text.utf8.count > 15 ? text.utf8.count : 0

      if text.isEmpty {
        keys.append(.empty)
      } else if let number = CSVRule.number(text) {
        keys.append(.number(number))
      } else {
        keys.append(.text(text.lowercased()))
      }
    }

    let ascending = spec.ascending
    let order = Array(rows.indices)

    let sorted = order.sorted { left, right in
      let result = compare(keys[left], keys[right])

      if result == .orderedSame { return left < right }

      if case .empty = keys[left] { return false }
      if case .empty = keys[right] { return true }

      return ascending ? result == .orderedAscending : result == .orderedDescending
    }

    return .sorted(sorted.map { rows[$0] })
  }

  private static func compare(_ left: Key, _ right: Key) -> ComparisonResult {
    switch (left, right) {
    case (.empty, .empty): return .orderedSame
    case (.empty, _): return .orderedDescending
    case (_, .empty): return .orderedAscending
    case (.number(let a), .number(let b)):
      return a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
    case (.number, .text): return .orderedAscending
    case (.text, .number): return .orderedDescending
    case (.text(let a), .text(let b)):
      return a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
    }
  }
}

/// Finds a needle in a cell, ignoring case. An ASCII needle searches the cell's bytes. Bytes of a
/// multi-byte character never equal an ASCII byte, so the search needs no decoding. Any other needle
/// decodes each cell.
private struct CellMatcher {
  private let ascii: [UInt8]?
  private let lowered: String

  init(_ needle: String) {
    lowered = needle.lowercased()

    let bytes = Array(needle.utf8)
    ascii = bytes.allSatisfy { $0 < 0x80 } ? bytes.map(Self.fold) : nil
  }

  func matches(_ cell: ArraySlice<UInt8>) -> Bool {
    guard let needle = ascii else {
      return String(decoding: cell, as: UTF8.self).lowercased().range(of: lowered) != nil
    }

    guard cell.count >= needle.count else { return false }

    let last = cell.endIndex - needle.count

    var start = cell.startIndex
    while start <= last {
      var offset = 0

      while offset < needle.count, Self.fold(cell[start + offset]) == needle[offset] {
        offset += 1
      }

      if offset == needle.count { return true }

      start += 1
    }

    return false
  }

  private static func fold(_ byte: UInt8) -> UInt8 {
    byte >= 0x41 && byte <= 0x5A ? byte + 0x20 : byte
  }
}
