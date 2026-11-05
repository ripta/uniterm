import Foundation

/// What a cell holds. A CSV cell is `text`, and a reader that knows more says so. JSON cells carry
/// the kinds below, so a sort can tell the string `"12"` from the number 12, and the view can show
/// `null` apart from a missing key.
public enum CellKind: UInt8, Sendable {
  /// A CSV cell. Its content decides how it sorts.
  case text = 0

  /// No value: a key the row lacks.
  case missing = 1

  case null = 2
  case bool = 3
  case number = 4
  case string = 5

  /// An object or an array that opens as a table. The bytes are its compact JSON text.
  case nested = 6
}

/// One cell of a typed row, as a reader hands it to the store.
struct TypedCell {
  var column: Int
  var kind: CellKind
  var bytes: [UInt8]
}

/// A sealed run of rows. The text of every cell sits in one byte buffer, and two offset tables
/// find the cells. A page never changes after it is sealed, so snapshots share pages.
///
/// A CSV page holds a cell for every column up to the row's own width, in column order. A typed
/// page holds only the cells a row has. It adds a kind and a column number for each cell, sorted by
/// column, so a lookup is a binary search and an absent column is a missing cell.
///
/// Offsets are `UInt32`. A page seals at about a megabyte, and one row is capped far below 4 GiB.
/// Column numbers are `UInt16`, which the JSON column cap stays well under.
public final class RowPage: Sendable {
  /// Every cell's UTF-8 text, row after row.
  let bytes: [UInt8]

  /// The end offset in `bytes` of each cell, row-major. A cell starts where the one before ended.
  let cellEnds: [UInt32]

  /// The index into `cellEnds` of each row's first cell, with one extra entry for the end.
  let rowFirstCell: [UInt32]

  /// A typed page's kind for each cell. Empty on a CSV page.
  let kinds: [UInt8]

  /// A typed page's column for each cell. Empty on a CSV page.
  let cellColumns: [UInt16]

  let isTyped: Bool

  init(
    bytes: [UInt8], cellEnds: [UInt32], rowFirstCell: [UInt32], kinds: [UInt8] = [],
    cellColumns: [UInt16] = [], isTyped: Bool = false
  ) {
    self.bytes = bytes
    self.cellEnds = cellEnds
    self.rowFirstCell = rowFirstCell
    self.kinds = kinds
    self.cellColumns = cellColumns
    self.isTyped = isTyped
  }

  public var rowCount: Int { rowFirstCell.count - 1 }

  /// What the page takes from the memory budget.
  public var cost: Int {
    bytes.count + MemoryLayout<UInt32>.stride * (cellEnds.count + rowFirstCell.count) + kinds.count
      + MemoryLayout<UInt16>.stride * cellColumns.count
  }

  /// How many cells the row holds. On a typed page that is the cells present, not the columns.
  func cellCount(row: Int) -> Int {
    Int(rowFirstCell[row + 1] - rowFirstCell[row])
  }

  func cell(row: Int, column: Int) -> ArraySlice<UInt8> {
    guard let index = cellIndex(row: row, column: column) else { return [] }

    return bytes[start(of: index)..<Int(cellEnds[index])]
  }

  func kind(row: Int, column: Int) -> CellKind {
    guard isTyped else { return .text }

    guard let index = cellIndex(row: row, column: column) else { return .missing }

    return CellKind(rawValue: kinds[index]) ?? .string
  }

  func start(of index: Int) -> Int {
    index == 0 ? 0 : Int(cellEnds[index - 1])
  }

  /// The position in `cellEnds` of the row's cell for `column`, or nil when the row has none.
  private func cellIndex(row: Int, column: Int) -> Int? {
    let first = Int(rowFirstCell[row])
    let end = Int(rowFirstCell[row + 1])

    guard isTyped else {
      return column >= 0 && column < end - first ? first + column : nil
    }

    var low = first
    var high = end

    while low < high {
      let middle = (low + high) / 2

      if Int(cellColumns[middle]) < column {
        low = middle + 1
      } else {
        high = middle
      }
    }

    return low < end && Int(cellColumns[low]) == column ? low : nil
  }
}

/// The page being filled. Only the loader touches it.
struct RowPageBuilder {
  private(set) var bytes: [UInt8] = []
  private(set) var cellEnds: [UInt32] = []
  private var rowFirstCell: [UInt32] = []
  private var kinds: [UInt8] = []
  private var cellColumns: [UInt16] = []
  private var isTyped = false

  var rowCount: Int { rowFirstCell.count }

  var cost: Int {
    bytes.count + MemoryLayout<UInt32>.stride * (cellEnds.count + rowFirstCell.count + 1)
      + kinds.count + MemoryLayout<UInt16>.stride * cellColumns.count
  }

  /// Adds a row. `ends` are end offsets relative to the start of `row`.
  mutating func append(row: [UInt8], ends: [UInt32]) {
    let base = UInt32(bytes.count)

    rowFirstCell.append(UInt32(cellEnds.count))
    bytes.append(contentsOf: row)
    cellEnds.append(contentsOf: ends.lazy.map { $0 + base })
  }

  /// Adds a typed row. `cells` are sorted by column, with no column twice.
  mutating func append(typed cells: [TypedCell]) {
    isTyped = true
    rowFirstCell.append(UInt32(cellEnds.count))

    for cell in cells {
      bytes.append(contentsOf: cell.bytes)
      cellEnds.append(UInt32(bytes.count))
      kinds.append(cell.kind.rawValue)
      cellColumns.append(UInt16(cell.column))
    }
  }

  /// The page, in arrays that hold exactly what the budget is charged for. The builder's arrays
  /// grow geometrically, so handing them over would keep up to twice the charged memory.
  func sealed() -> RowPage {
    RowPage(
      bytes: Self.exact(bytes), cellEnds: Self.exact(cellEnds),
      rowFirstCell: Self.exact(rowFirstCell + [UInt32(cellEnds.count)]),
      kinds: Self.exact(kinds), cellColumns: Self.exact(cellColumns), isTyped: isTyped)
  }

  private static func exact<Element: BitwiseCopyable>(_ array: [Element]) -> [Element] {
    array.withUnsafeBufferPointer { source in
      [Element](unsafeUninitializedCapacity: source.count) { target, count in
        if let from = source.baseAddress, let to = target.baseAddress {
          to.initialize(from: from, count: source.count)
        }

        count = source.count
      }
    }
  }

  mutating func reset() {
    self = RowPageBuilder()
  }
}
