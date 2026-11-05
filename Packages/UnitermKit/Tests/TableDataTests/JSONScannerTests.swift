import XCTest

@testable import TableData

/// Runs the scanner over chunks and writes each event as a line of text, with the depth and offsets
/// the scanner reports. Two runs over the same bytes must give the same lines, however the bytes
/// are split.
func scanEvents(
  _ chunks: [ArraySlice<UInt8>], mode: JSONScanner.Mode = .single, captureAt: Int? = nil
) -> [String] {
  var scanner = JSONScanner(mode: mode, captureAt: captureAt)
  var lines: [String] = []

  let sink: (JSONEvent, JSONContext) -> Bool = { event, context in
    let base = "\(context.depth)/\(context.valueCount)/\(context.start)-\(context.end)"
    let captured = String(decoding: context.captured, as: UTF8.self)

    switch event {
    case .beginObject: lines.append("{ \(base) \(captured)")
    case .endObject: lines.append("} \(base) \(captured)")
    case .beginArray: lines.append("[ \(base) \(captured)")
    case .endArray: lines.append("] \(base) \(captured)")
    case .key(let bytes): lines.append("key \(String(decoding: bytes, as: UTF8.self)) \(base)")
    case .string(let bytes): lines.append("str \(String(decoding: bytes, as: UTF8.self)) \(base)")
    case .number(let bytes): lines.append("num \(String(decoding: bytes, as: UTF8.self)) \(base)")
    case .bool(let value): lines.append("bool \(value) \(base)")
    case .null: lines.append("null \(base)")
    }

    return true
  }

  do {
    for chunk in chunks {
      _ = try scanner.feed(chunk, sink: sink)
    }

    try scanner.finish(sink: sink)
  } catch let error as JSONSyntaxError {
    lines.append("error \(error.reason) \(error.line):\(error.column)")
  } catch {
    lines.append("error \(error)")
  }

  return lines
}

final class JSONScannerTests: XCTestCase {
  /// Catches a token that breaks when a read ends inside it: a string, an escape, a surrogate
  /// pair, a number, or a word. Splitting at every offset, and into single bytes, gives the same
  /// events, offsets, and captured text as one read.
  func testSplittingTheInputAnywhereNeverChangesTheEvents() {
    let documents: [(String, JSONScanner.Mode, Int?)] = [
      (#"{"a":[1,-2.5e3,true,false,null,"sé😀\n"],"b\"":{"c":{}},"d":[]}"#, .single, nil),
      (#"[{"x":1},{"y":[2,3]},4,"z"]"#, .single, 2),
      ("{\"a\":1}\n[2]\n\"three\"\n4\n", .lines, 1),
      (#"[1,2,"unterminated"#, .single, nil),
      (#"{"a":tru}"#, .single, nil),
    ]

    for (text, mode, capture) in documents {
      let bytes = Array(text.utf8)
      let whole = scanEvents([bytes[...]], mode: mode, captureAt: capture)

      for split in 0...bytes.count {
        let halves = [bytes[..<split], bytes[split...]]
        XCTAssertEqual(
          scanEvents(halves, mode: mode, captureAt: capture), whole, "\(text) split at \(split)")
      }

      let singles = bytes.indices.map { bytes[$0...$0] }
      XCTAssertEqual(scanEvents(singles, mode: mode, captureAt: capture), whole, text)
    }
  }

  /// Catches a captured element that misses a byte or runs past its end. The scanner hands back
  /// each container that opens at the capture depth, from its opening bracket to its closing one.
  func testCaptureHoldsEachElementWhole() {
    let bytes = Array(#"[ {"x": 1} , [2, 3],4]"#.utf8)
    let events = scanEvents([bytes[...]], captureAt: 2)
    let ends = events.filter { $0.hasPrefix("} 1/") || $0.hasPrefix("] 1/") }

    XCTAssertEqual(
      ends.map { String($0.split(separator: " ", maxSplits: 2)[2]) },
      [
        #"{"x": 1}"#, "[2, 3]",
      ])
  }

  /// Catches the number grammar drifting from RFC 8259.
  func testNumberGrammar() {
    for valid in ["0", "-0", "1", "10", "1.5", "-1.5e+10", "2E-3", "0.0"] {
      XCTAssertTrue(JSONScanner.isValidNumber(Array(valid.utf8)), valid)
    }

    for invalid in ["", "-", "01", "1.", ".5", "1e", "1e+", "+1", "--1", "1.2.3", "0x1"] {
      XCTAssertFalse(JSONScanner.isValidNumber(Array(invalid.utf8)), invalid)
    }
  }
}
