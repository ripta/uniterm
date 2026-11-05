import Foundation

/// A streaming CSV parser over UTF-8 bytes. Feed it chunks in order. It calls the sink once for each
/// row, with the row's cell bytes joined and the end offset of each cell.
///
/// The dialect is lenient, since real files are:
/// - A field that starts with a quote runs to the closing quote. A doubled quote inside is one
///   quote. Newlines inside belong to the field.
/// - A quote in the middle of an unquoted field is literal text.
/// - Text after a closing quote joins the field.
/// - A row ends at LF, CR, or CR LF. A line with nothing on it is skipped.
/// - A quote still open at the end of the file ends there. The field keeps what it read.
///
/// A cell keeps at most `maxCellBytes`, a row at most `maxRowBytes` and `maxCells` cells. What a
/// cap drops is counted in `truncatedRows`, so the pane can say that it cut something.
struct CSVParser {
  static let maxCellBytes = 1 << 20
  static let maxRowBytes = 16 << 20
  static let maxCells = 1 << 16

  /// Gets the row's bytes and cell ends. Returns false to stop the parse.
  typealias Sink = (_ row: [UInt8], _ ends: [UInt32]) -> Bool

  private enum State {
    case fieldStart
    case unquoted
    case quoted
    case quoteInQuoted
  }

  private let delimiter: UInt8
  private var state = State.fieldStart
  private var row: [UInt8] = []
  private var ends: [UInt32] = []
  private var fieldStart = 0
  private var afterCarriageReturn = false
  private var rowTruncated = false
  private(set) var truncatedRows = 0
  private(set) var stopped = false

  init(delimiter: UInt8) {
    self.delimiter = delimiter
  }

  mutating func feed(_ bytes: ArraySlice<UInt8>, sink: Sink) {
    for byte in bytes {
      if stopped { return }

      if afterCarriageReturn {
        afterCarriageReturn = false

        if byte == 0x0A { continue }
      }

      step(byte, sink: sink)
    }
  }

  /// Ends the file. A row with no final newline still comes out.
  mutating func finish(sink: Sink) {
    guard !stopped else { return }

    if state != .fieldStart || !ends.isEmpty {
      endRow(sink: sink)
    }
  }

  private mutating func step(_ byte: UInt8, sink: Sink) {
    switch state {
    case .fieldStart:
      if byte == UInt8(ascii: "\"") {
        state = .quoted
      } else if byte == delimiter {
        endField()
      } else if isNewline(byte) {
        endRow(sink: sink, carriageReturn: byte == 0x0D)
      } else {
        append(byte)
        state = .unquoted
      }

    case .unquoted:
      if byte == delimiter {
        endField()
        state = .fieldStart
      } else if isNewline(byte) {
        endRow(sink: sink, carriageReturn: byte == 0x0D)
      } else {
        append(byte)
      }

    case .quoted:
      if byte == UInt8(ascii: "\"") {
        state = .quoteInQuoted
      } else {
        append(byte)
      }

    case .quoteInQuoted:
      if byte == UInt8(ascii: "\"") {
        append(byte)
        state = .quoted
      } else if byte == delimiter {
        endField()
        state = .fieldStart
      } else if isNewline(byte) {
        endRow(sink: sink, carriageReturn: byte == 0x0D)
      } else {
        append(byte)
        state = .unquoted
      }
    }
  }

  private func isNewline(_ byte: UInt8) -> Bool {
    byte == 0x0A || byte == 0x0D
  }

  private mutating func append(_ byte: UInt8) {
    guard ends.count < Self.maxCells, row.count < Self.maxRowBytes,
      row.count - fieldStart < Self.maxCellBytes
    else {
      rowTruncated = true
      return
    }

    row.append(byte)
  }

  private mutating func endField() {
    if ends.count < Self.maxCells {
      ends.append(UInt32(row.count))
      fieldStart = row.count
    } else {
      rowTruncated = true
    }
  }

  private mutating func endRow(sink: Sink, carriageReturn: Bool = false) {
    afterCarriageReturn = carriageReturn

    if state == .fieldStart && ends.isEmpty {
      return
    }

    endField()

    if rowTruncated {
      truncatedRows += 1
    }

    if !sink(row, ends) {
      stopped = true
    }

    row.removeAll(keepingCapacity: true)
    ends.removeAll(keepingCapacity: true)
    fieldStart = 0
    rowTruncated = false
    state = .fieldStart
  }
}
