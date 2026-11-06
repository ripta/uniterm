import Foundation

/// A cell of a flattened row, before it has a column number. A path column names its key
/// segments. A positional cell names its position in an array.
struct ShapedCell {
  var segments: [String]
  var position: Int
  var isScalarRow = false
  var kind: CellKind
  var bytes: [UInt8]

  /// The title of the column this cell lands in.
  var title: String {
    guard segments.isEmpty else { return JSONRule.title(of: segments) }

    return isScalarRow ? "value" : "Column \(position + 1)"
  }
}

/// Flattens one array element, one JSON Lines value, or one nested value into cells, by the rules
/// in `JSONRule`. The input is a whole value that the scanner already checked.
enum JSONShaper {
  private struct Frame {
    var isObject: Bool
    var depth: Int
    var start: Int
    var entryStart: Int
    var members = 0
    var index = 0
    var key = ""
  }

  /// A value being copied into one expandable cell, from its start to the end event that brings
  /// the depth down to `endDepth`.
  private struct Skip {
    var endDepth: Int
    var start: Int
    var segments: [String]
    var position: Int
  }

  /// The cells of `element`, and how many values a size cap replaced by a note.
  static func flatten(_ element: [UInt8]) -> (cells: [ShapedCell], cut: Int) {
    var cells: [ShapedCell] = []
    var cut = 0
    var dropped = false
    var frames: [Frame] = []
    var skip: Skip?
    var scanner = JSONScanner(mode: .single)

    func add(_ cell: ShapedCell) {
      if cells.count < JSONRule.maxCellsPerRow {
        cells.append(cell)
      } else {
        dropped = true
      }
    }

    func path() -> [String] {
      frames.filter(\.isObject).map(\.key)
    }

    func nested(_ range: Range<Int>, segments: [String], position: Int) {
      let compact = Self.compact(element[range])

      if compact.count > JSONRule.maxStringBytes {
        cut += 1
        add(
          ShapedCell(
            segments: segments, position: position, kind: .string,
            bytes: Array(JSONRule.tooLargeNote.utf8)))
      } else {
        add(
          ShapedCell(segments: segments, position: position, kind: .nested, bytes: compact))
      }
    }

    func scalar(_ kind: CellKind, _ bytes: [UInt8]) {
      guard let last = frames.indices.last else {
        add(
          ShapedCell(
            segments: [], position: 0, isScalarRow: true, kind: kind, bytes: bytes))
        return
      }

      if frames[last].isObject {
        add(ShapedCell(segments: path(), position: -1, kind: kind, bytes: bytes))
      } else {
        add(
          ShapedCell(segments: [], position: frames[last].index, kind: kind, bytes: bytes))
        frames[last].index += 1
      }
    }

    func begin(isObject: Bool, _ context: JSONContext) {
      let frame = Frame(
        isObject: isObject, depth: context.depth, start: context.start, entryStart: cells.count)

      guard let last = frames.indices.last else {
        frames.append(frame)
        return
      }

      if isObject, frames[last].isObject, frames.count < JSONRule.maxFlattenDepth {
        frames.append(frame)
        return
      }

      let inObject = frames[last].isObject
      let position = inObject ? -1 : frames[last].index

      if !inObject { frames[last].index += 1 }

      skip = Skip(
        endDepth: context.depth - 1, start: context.start, segments: inObject ? path() : [],
        position: position)
    }

    let sink: (JSONEvent, JSONContext) -> Bool = { event, context in
      if let pending = skip {
        switch event {
        case .endObject, .endArray:
          if context.depth == pending.endDepth {
            nested(
              pending.start..<context.end, segments: pending.segments, position: pending.position)
            skip = nil
          }

        default:
          break
        }

        return true
      }

      switch event {
      case .key(let bytes):
        guard let last = frames.indices.last, frames[last].isObject else { return true }

        frames[last].key = String(decoding: bytes, as: UTF8.self)
        frames[last].members += 1

        if frames.count > 1, frames[last].members > JSONRule.maxMapMembers {
          let map = frames.removeLast()
          cells.removeSubrange(map.entryStart...)
          skip = Skip(
            endDepth: map.depth - 1, start: map.start, segments: path(), position: -1)
        }

      case .beginObject:
        begin(isObject: true, context)

      case .beginArray:
        begin(isObject: false, context)

      case .endObject, .endArray:
        guard let frame = frames.popLast() else { return true }

        if frame.isObject, !frames.isEmpty, frame.members == 0 {
          add(
            ShapedCell(segments: path(), position: -1, kind: .nested, bytes: Array("{}".utf8)))
        }

      case .string(let bytes):
        scalar(.string, bytes)

      case .number(let bytes):
        scalar(.number, bytes)

      case .bool(let value):
        scalar(.bool, Array((value ? "true" : "false").utf8))

      case .null:
        scalar(.null, Array("null".utf8))
      }

      return true
    }

    _ = try? scanner.feed(element[...], sink: sink)

    return (cells, cut + (dropped ? 1 : 0))
  }

  /// The value's JSON text without the whitespace between tokens.
  static func compact(_ raw: ArraySlice<UInt8>) -> [UInt8] {
    var output: [UInt8] = []
    output.reserveCapacity(raw.count)

    var inString = false
    var escaped = false

    for byte in raw {
      if inString {
        output.append(byte)

        if escaped {
          escaped = false
        } else if byte == UInt8(ascii: "\\") {
          escaped = true
        } else if byte == UInt8(ascii: "\"") {
          inString = false
        }

        continue
      }

      switch byte {
      case 0x20, 0x09, 0x0A, 0x0D:
        continue

      case UInt8(ascii: "\""):
        inString = true
        output.append(byte)

      default:
        output.append(byte)
      }
    }

    return output
  }

  /// A string's bytes as a JSON string, quotes included.
  static func quoted(_ bytes: [UInt8]) -> [UInt8] {
    var output: [UInt8] = [UInt8(ascii: "\"")]

    for byte in bytes {
      switch byte {
      case UInt8(ascii: "\""), UInt8(ascii: "\\"):
        output.append(UInt8(ascii: "\\"))
        output.append(byte)

      case 0..<0x20:
        output.append(contentsOf: Array(String(format: "\\u%04x", UInt32(byte)).utf8))

      default:
        output.append(byte)
      }
    }

    output.append(UInt8(ascii: "\""))
    return output
  }
}

/// The columns of a JSON table. They only grow, in first-seen order, so row N keeps meaning the
/// same cells as the table fills.
struct JSONColumns {
  private(set) var columns: [TableColumn] = []
  private var index: [ColumnIdentity: Int] = [:]
  private var rowCounts: [[String]: Int] = [:]
  private var rowPositions: Set<Int> = []
  private var overflow: Int?

  /// What the last column holds when the table hit `JSONRule.maxColumns`.
  static let overflowIdentity = ColumnIdentity(segments: [], occurrence: -1)

  /// The row's cells with their column numbers, sorted by column. Values past the column cap
  /// are folded into the overflow cell, and `cut` counts what the folded cell could not hold.
  mutating func place(_ shaped: [ShapedCell]) -> (cells: [TypedCell], cut: Int) {
    rowCounts.removeAll(keepingCapacity: true)
    rowPositions.removeAll(keepingCapacity: true)

    var placed: [TypedCell] = []
    placed.reserveCapacity(shaped.count)

    var extra: [(title: String, cell: ShapedCell)] = []

    for cell in shaped {
      if let column = column(for: cell) {
        placed.append(TypedCell(column: column, kind: cell.kind, bytes: cell.bytes))
      } else {
        extra.append((cell.title, cell))
      }
    }

    var cut = 0

    if !extra.isEmpty {
      let (bytes, folded) = Self.fold(extra)
      cut = folded

      placed.append(
        TypedCell(column: overflowColumn(), kind: .nested, bytes: bytes))
    }

    placed.sort { $0.column < $1.column }
    return (placed, cut)
  }

  /// The column for a cell. The nth time a key path repeats in one row, the cell goes to the path's
  /// nth column, found in constant time however many repeats came before.
  private mutating func column(for cell: ShapedCell) -> Int? {
    let identity: ColumnIdentity

    if cell.segments.isEmpty {
      guard rowPositions.insert(cell.position).inserted else { return nil }

      identity = .positional(cell.position)
    } else {
      let occurrence = rowCounts[cell.segments, default: 0]
      rowCounts[cell.segments] = occurrence + 1
      identity = ColumnIdentity(segments: cell.segments, occurrence: occurrence)
    }

    if let found = index[identity] { return found }

    guard columns.count < JSONRule.maxColumns else { return nil }

    index[identity] = columns.count
    columns.append(TableColumn(identity: identity, title: cell.title))
    return columns.count - 1
  }

  private mutating func overflowColumn() -> Int {
    if let overflow { return overflow }

    columns.append(TableColumn(identity: Self.overflowIdentity, title: "(more keys)"))
    overflow = columns.count - 1
    return columns.count - 1
  }

  /// An object of the cells that found no column, keyed by their titles.
  private static func fold(_ cells: [(title: String, cell: ShapedCell)]) -> ([UInt8], Int) {
    var bytes: [UInt8] = [UInt8(ascii: "{")]
    var cut = 0

    for (title, cell) in cells {
      let value: [UInt8] =
        cell.kind == .string ? JSONShaper.quoted(cell.bytes) : cell.bytes
      let member = JSONShaper.quoted(Array(title.utf8)) + [UInt8(ascii: ":")] + value

      if bytes.count + member.count + 2 > JSONRule.maxStringBytes {
        cut += 1
        continue
      }

      if bytes.count > 1 { bytes.append(UInt8(ascii: ",")) }

      bytes.append(contentsOf: member)
    }

    bytes.append(UInt8(ascii: "}"))
    return (bytes, cut)
  }
}
