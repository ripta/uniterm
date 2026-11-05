import Foundation

/// A sealed run of rows. The text of every cell sits in one byte buffer, and two offset tables
/// find the cells. A page never changes after it is sealed, so snapshots share pages.
///
/// Offsets are `UInt32`. A page seals at about a megabyte, and one row is capped far below 4 GiB.
public final class RowPage: Sendable {
  /// Every cell's UTF-8 text, row after row.
  let bytes: [UInt8]

  /// The end offset in `bytes` of each cell, row-major. A cell starts where the one before ended.
  let cellEnds: [UInt32]

  /// The index into `cellEnds` of each row's first cell, with one extra entry for the end.
  let rowFirstCell: [UInt32]

  init(bytes: [UInt8], cellEnds: [UInt32], rowFirstCell: [UInt32]) {
    self.bytes = bytes
    self.cellEnds = cellEnds
    self.rowFirstCell = rowFirstCell
  }

  public var rowCount: Int { rowFirstCell.count - 1 }

  /// What the page takes from the memory budget.
  public var cost: Int {
    bytes.count + MemoryLayout<UInt32>.stride * (cellEnds.count + rowFirstCell.count)
  }

  func cellCount(row: Int) -> Int {
    Int(rowFirstCell[row + 1] - rowFirstCell[row])
  }

  func cell(row: Int, column: Int) -> ArraySlice<UInt8> {
    guard column < cellCount(row: row) else { return [] }

    let index = Int(rowFirstCell[row]) + column
    let start = index == 0 ? 0 : Int(cellEnds[index - 1])

    return bytes[start..<Int(cellEnds[index])]
  }
}

/// The page being filled. Only the loader touches it.
struct RowPageBuilder {
  private(set) var bytes: [UInt8] = []
  private(set) var cellEnds: [UInt32] = []
  private var rowFirstCell: [UInt32] = []

  var rowCount: Int { rowFirstCell.count }

  var cost: Int {
    bytes.count + MemoryLayout<UInt32>.stride * (cellEnds.count + rowFirstCell.count + 1)
  }

  /// Adds a row. `ends` are end offsets relative to the start of `row`.
  mutating func append(row: [UInt8], ends: [UInt32]) {
    let base = UInt32(bytes.count)

    rowFirstCell.append(UInt32(cellEnds.count))
    bytes.append(contentsOf: row)
    cellEnds.append(contentsOf: ends.lazy.map { $0 + base })
  }

  /// The page, in arrays that hold exactly what the budget is charged for. The builder's arrays
  /// grow geometrically, so handing them over would keep up to twice the charged memory.
  func sealed() -> RowPage {
    RowPage(
      bytes: Self.exact(bytes), cellEnds: Self.exact(cellEnds),
      rowFirstCell: Self.exact(rowFirstCell + [UInt32(cellEnds.count)]))
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
