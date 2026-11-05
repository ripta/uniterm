import Foundation

/// The rows loaded so far, frozen. Rows only ever append, so row N of one snapshot is row N of every
/// later snapshot of the same load. A snapshot is cheap to copy: it holds sealed pages by reference.
public struct TableSnapshot: Sendable {
  public let columns: [TableColumn]
  let pages: [RowPage]
  private let pageStarts: [Int]
  public let rowCount: Int

  public static let empty = TableSnapshot(columns: [], pages: [])

  init(columns: [TableColumn], pages: [RowPage]) {
    self.columns = columns
    self.pages = pages

    var starts: [Int] = []
    var total = 0

    for page in pages {
      starts.append(total)
      total += page.rowCount
    }

    pageStarts = starts
    rowCount = total
  }

  /// The UTF-8 bytes of a cell. A row shorter than the table, or a row past the end, has empty
  /// cells.
  public func cell(row: Int, column: Int) -> ArraySlice<UInt8> {
    guard row >= 0, row < rowCount else { return [] }

    let (page, local) = locate(row)
    return pages[page].cell(row: local, column: column)
  }

  /// What a cell holds. A CSV cell is always `text`. A JSON row lacking the column is `missing`.
  public func kind(row: Int, column: Int) -> CellKind {
    guard row >= 0, row < rowCount else { return .missing }

    let (page, local) = locate(row)
    return pages[page].kind(row: local, column: column)
  }

  /// A cell as text, at most `limit` bytes of it. Bytes that are not valid UTF-8 show as U+FFFD,
  /// and a cut text ends in an ellipsis.
  public func text(row: Int, column: Int, limit: Int = 2_000) -> String {
    let bytes = cell(row: row, column: column)

    guard bytes.count > limit else { return String(decoding: bytes, as: UTF8.self) }

    var end = bytes.startIndex + limit

    while end > bytes.startIndex, bytes[end] & 0xC0 == 0x80 {
      end -= 1
    }

    return String(decoding: bytes[bytes.startIndex..<end], as: UTF8.self) + "\u{2026}"
  }

  func forEachRow(_ body: (_ row: Int, _ page: RowPage, _ local: Int) -> Bool) {
    for (index, page) in pages.enumerated() {
      for local in 0..<page.rowCount {
        if !body(pageStarts[index] + local, page, local) { return }
      }
    }
  }

  private func locate(_ row: Int) -> (page: Int, local: Int) {
    var low = 0
    var high = pageStarts.count - 1

    while low < high {
      let middle = (low + high + 1) / 2

      if pageStarts[middle] <= row {
        low = middle
      } else {
        high = middle - 1
      }
    }

    return (low, row - pageStarts[low])
  }
}
