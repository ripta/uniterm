import Foundation

/// What a single JSON value turned out to hold, from its first token.
enum JSONTop {
  case unknown
  case array
  case object

  /// A scalar on its own, described for the pane's message.
  case scalar(String)
}

/// The JSON side of a load. It feeds the scanner, turns each array element, object member, or JSON
/// Lines value into a row, and hands the row to the same page store, budget, and snapshots that
/// CSV uses. The rules are in `JSONRule`.
extension LoadRun {
  mutating func readJSON(from descriptor: Int32, fileExtension: String, path: String) {
    var chunk = [UInt8](repeating: 0, count: 256 << 10)
    var sample: [UInt8] = []
    var atEnd = false

    while sample.count < JSONRule.sampleSize, !atEnd {
      guard let count = fill(descriptor, &chunk, into: &sample, path: path) else { return }

      atEnd = count == 0
    }

    let head = Array(sample.prefix(JSONRule.sampleSize))
    let (detected, bom) = CSVRule.encoding(
      of: head, isWholeFile: atEnd && head.count == sample.count)

    // JSON is UTF-8. Bytes that are not valid UTF-8 show as U+FFFD, not as Windows-1252.
    let encoding = detected == .windows1252 ? CSVEncoding.utf8 : detected

    var sniffed: [UInt8] = []
    var sniffer = TextTranscoder(encoding)
    sniffer.convert(head[bom...], final: false, into: &sniffed)

    let lines = JSONRule.isLines(fileExtension: fileExtension, sample: sniffed[...])
    var scanner = JSONScanner(mode: lines ? .lines : .single, captureAt: lines ? 1 : 2)

    isJSON = true

    var transcoder = TextTranscoder(encoding)
    var text: [UInt8] = []
    transcoder.convert(sample[bom...], final: atEnd, into: &text)

    feed(&scanner, text[...], path: path)

    var raw: [UInt8] = []

    while !atEnd, end == nil {
      if isCancelled() {
        finish(.cancelled)
        return
      }

      raw.removeAll(keepingCapacity: true)

      guard let count = fill(descriptor, &chunk, into: &raw, path: path) else { return }

      atEnd = count == 0
      text.removeAll(keepingCapacity: true)
      transcoder.convert(raw[...], final: atEnd, into: &text)
      feed(&scanner, text[...], path: path)
    }

    finishJSON(&scanner, path: path)
  }

  /// Loads a nested value that is already in memory. It is one JSON value in UTF-8.
  mutating func load(embedded bytes: [UInt8], name: String) {
    isJSON = true
    progress.totalBytes = bytes.count

    var scanner = JSONScanner(mode: .single, captureAt: 2)
    var offset = 0

    while offset < bytes.count, end == nil {
      if isCancelled() {
        finish(.cancelled)
        return
      }

      let next = min(offset + (256 << 10), bytes.count)

      feed(&scanner, bytes[offset..<next], path: name)
      progress.bytesRead = next
      offset = next
    }

    finishJSON(&scanner, path: name)
  }

  private mutating func feed(_ scanner: inout JSONScanner, _ text: ArraySlice<UInt8>, path: String)
  {
    guard end == nil else { return }

    let lines = scanner.mode == .lines

    do {
      _ = try scanner.feed(text) { event, context in
        handle(event, context, lines: lines)
      }
    } catch let error as JSONSyntaxError {
      finish(.failed(.invalidJSON(path: path, reason: error.reason, line: error.line)))
      return
    } catch {
      finish(.failed(.invalidJSON(path: path, reason: "\(error)", line: 0)))
      return
    }

    publishIfDue()
  }

  private mutating func finishJSON(_ scanner: inout JSONScanner, path: String) {
    guard end == nil else { return }

    let lines = scanner.mode == .lines

    do {
      try scanner.finish { event, context in
        handle(event, context, lines: lines)
      }
    } catch let error as JSONSyntaxError {
      finish(.failed(.invalidJSON(path: path, reason: error.reason, line: error.line)))
      return
    } catch {
      finish(.failed(.invalidJSON(path: path, reason: "\(error)", line: 0)))
      return
    }

    guard end == nil else { return }

    if case .scalar(let what) = jsonTop {
      finish(.failed(.notATable(path: path, what: what)))
      return
    }

    if !sealPage() { return }

    finish(.completed)
  }

  // MARK: Events

  /// Returns false to stop the scanner, after the load has ended.
  private mutating func handle(_ event: JSONEvent, _ context: JSONContext, lines: Bool) -> Bool {
    guard end == nil else { return false }

    let elementDepth = lines ? 0 : 1

    switch event {
    case .beginObject:
      if !lines, context.depth == 1 { jsonTop = .object }

      return true

    case .beginArray:
      if !lines, context.depth == 1 { jsonTop = .array }

      return true

    case .endObject, .endArray:
      return context.depth == elementDepth ? acceptContainer(context) : true

    case .key(let bytes):
      if !lines, context.depth == 1 { jsonKey = bytes }

      return true

    case .string(let bytes):
      return acceptScalar(.string, bytes, "a string", context, lines: lines)

    case .number(let bytes):
      return acceptScalar(.number, bytes, "a number", context, lines: lines)

    case .bool(let value):
      return acceptScalar(
        .bool, Array((value ? "true" : "false").utf8), "true or false", context, lines: lines)

    case .null:
      return acceptScalar(.null, Array("null".utf8), "null", context, lines: lines)
    }
  }

  private mutating func acceptScalar(
    _ kind: CellKind, _ bytes: [UInt8], _ what: String, _ context: JSONContext, lines: Bool
  ) -> Bool {
    if lines {
      guard context.depth == 0 else { return true }

      return accept(
        [ShapedCell(segments: [], position: 0, isScalarRow: true, kind: kind, bytes: bytes)],
        cut: 0, context)
    }

    switch context.depth {
    case 0:
      jsonTop = .scalar(what)
      return true

    case 1:
      if case .object = jsonTop {
        return accept(
          Self.memberCells(key: jsonKey ?? [], kind: kind, bytes: bytes), cut: 0, context)
      }

      return accept(
        [ShapedCell(segments: [], position: 0, isScalarRow: true, kind: kind, bytes: bytes)],
        cut: 0, context)

    default:
      return true
    }
  }

  /// A container element is complete. `context.captured` holds all of it.
  private mutating func acceptContainer(_ context: JSONContext) -> Bool {
    if case .object = jsonTop, context.depth == 1 {
      let compact = JSONShaper.compact(context.captured[...])
      let tooLarge = context.captureOverflow || compact.count > JSONRule.maxStringBytes

      return accept(
        Self.memberCells(
          key: jsonKey ?? [], kind: tooLarge ? .string : .nested,
          bytes: tooLarge ? Array(JSONRule.tooLargeNote.utf8) : compact),
        cut: tooLarge ? 1 : 0, context)
    }

    guard !context.captureOverflow else {
      return accept(
        [
          ShapedCell(
            segments: ["(too large)"], position: -1, kind: .string,
            bytes: Array(JSONRule.tooLargeNote.utf8))
        ], cut: 1, context)
    }

    let shaped = JSONShaper.flatten(context.captured)
    return accept(shaped.cells, cut: shaped.cut, context)
  }

  private static func memberCells(key: [UInt8], kind: CellKind, bytes: [UInt8]) -> [ShapedCell] {
    [
      ShapedCell(segments: ["key"], position: -1, kind: .string, bytes: key),
      ShapedCell(segments: ["value"], position: -1, kind: kind, bytes: bytes),
    ]
  }

  private mutating func accept(_ shaped: [ShapedCell], cut: Int, _ context: JSONContext) -> Bool {
    jsonRowCount += 1

    if jsonRowCount & 0xFF == 0, isCancelled() {
      finish(.cancelled)
      return false
    }

    let (cells, folded) = jsonColumns.place(shaped)

    builder.append(typed: cells)

    if cut + folded > 0 || context.truncatedValues != jsonTruncatedSeen {
      progress.truncatedRows += 1
    }

    jsonTruncatedSeen = context.truncatedValues

    if builder.cost >= pageTarget {
      _ = sealPage()
    }

    return end == nil
  }
}
