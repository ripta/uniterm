import Foundation

/// One token of a JSON document, with strings already unescaped into UTF-8.
enum JSONEvent {
  case beginObject
  case endObject
  case beginArray
  case endArray
  case key([UInt8])
  case string([UInt8])

  /// A number's original text, so a large integer or a long decimal is never rounded.
  case number([UInt8])
  case bool(Bool)
  case null
}

/// Where the scanner stands when it reports an event.
struct JSONContext {
  /// Containers open after the event.
  let depth: Int

  /// Top-level values finished before the event.
  let valueCount: Int

  /// The offsets of the event's token in the fed bytes. A container's begin has its opening
  /// byte's offset in `start`, and its end has the offset after its closing byte in `end`.
  let start: Int
  let end: Int

  /// The bytes of the container being captured, up to and including this event.
  let captured: [UInt8]

  /// True when the captured container passed the element size cap, so `captured` stops short.
  let captureOverflow: Bool

  /// Strings and keys cut at their caps so far.
  let truncatedValues: Int
}

struct JSONSyntaxError: Error, Equatable {
  var reason: String
  var line: Int
  var column: Int
}

/// A streaming, validating JSON tokenizer. It takes bytes in chunks of any size, holds only the token
/// it is inside, and reports events as it goes, so a large array is never parsed as a whole.
///
/// The syntax is RFC 8259. A raw control character inside a string is an error, and so is any
/// byte at or above 0x80 outside a string. Bytes that are not valid UTF-8 inside a string pass
/// through and show as U+FFFD later. A lone surrogate escape becomes U+FFFD.
///
/// Caps protect the host from a hostile file. Containers nest at most `maxDepth` deep, a string keeps
/// `JSONRule.maxStringBytes`, and a key keeps `maxKeyBytes`. A cut string is counted in
/// `truncatedValues`. A number longer than `maxNumberBytes` is not cut, since a cut number reads as a
/// different value. It is replaced by the too-large note, as a string event, and counted the same way.
///
/// `lines` mode accepts several top-level values, each starting after a new line, as JSON Lines
/// does. `single` mode accepts one.
///
/// With `captureAt` set, the scanner copies each container that opens at that depth, so the caller
/// gets one array element or one object member whole. The copy stops growing at
/// `JSONRule.maxElementBytes`, while the scanner goes on checking the syntax.
struct JSONScanner {
  enum Mode: Sendable {
    case single
    case lines
  }

  static let maxDepth = 256
  static let maxKeyBytes = 4096
  static let maxNumberBytes = 64 * 1024

  private enum Expect {
    case value
    case valueOrEnd
    case keyOrEnd
    case key
    case colon
    case commaOrEnd
    case afterTop
  }

  private enum Lex {
    case none
    case string(isKey: Bool)
    case escape(isKey: Bool)
    case unicode(isKey: Bool, digits: Int, value: UInt32)
    case number
    case word
  }

  let mode: Mode
  private let captureAt: Int?

  private var stack: [Bool] = []
  private var expect = Expect.value
  private var lex = Lex.none
  private var buffer: [UInt8] = []
  private var limit = 0
  private var truncated = false
  private var numberTooLong = false
  private var highSurrogate: UInt32?
  private var offset = 0
  private var line = 1
  private var lineStart = 0
  private var sawNewline = false
  private var tokenStart = 0
  private var tokenEnd = 0
  private var captured: [UInt8] = []
  private var capturing = false
  private var captureOverflow = false

  private(set) var valueCount = 0
  private(set) var truncatedValues = 0

  init(mode: Mode, captureAt: Int? = nil) {
    self.mode = mode
    self.captureAt = captureAt
  }

  /// Scans `chunk`. Returns false when the sink asked to stop.
  mutating func feed(
    _ chunk: ArraySlice<UInt8>, sink: (JSONEvent, JSONContext) -> Bool
  ) throws -> Bool {
    for byte in chunk {
      if capturing { appendCaptured(byte) }

      if byte == 0x0A {
        line += 1
        lineStart = offset + 1
      }

      guard try step(byte, sink) else { return false }

      offset += 1
    }

    return true
  }

  /// Ends the input. A number or word at the end finishes, and anything left open is an error.
  mutating func finish(sink: (JSONEvent, JSONContext) -> Bool) throws {
    switch lex {
    case .none:
      break

    case .number:
      _ = try finishNumber(sink)

    case .word:
      _ = try finishWord(sink)

    case .string, .escape, .unicode:
      throw fail("the file ends inside a string")
    }

    if let open = stack.last {
      throw fail(open ? "the file ends inside an object" : "the file ends inside an array")
    }
  }

  // MARK: Bytes

  private mutating func step(_ byte: UInt8, _ sink: (JSONEvent, JSONContext) -> Bool) throws -> Bool
  {
    switch lex {
    case .none:
      break

    case .string(let isKey):
      return try stringByte(byte, isKey: isKey, sink)

    case .escape(let isKey):
      return try escapeByte(byte, isKey: isKey)

    case .unicode(let isKey, let digits, let value):
      return try unicodeByte(byte, isKey: isKey, digits: digits, value: value)

    case .number:
      if Self.isNumberByte(byte) {
        if buffer.count < Self.maxNumberBytes {
          buffer.append(byte)
        } else {
          numberTooLong = true
        }

        return true
      }

      guard try finishNumber(sink) else { return false }

    case .word:
      if byte >= 0x61 && byte <= 0x7A {
        guard buffer.count < 5 else { throw fail("unexpected text") }

        buffer.append(byte)
        return true
      }

      guard try finishWord(sink) else { return false }
    }

    return try dispatch(byte, sink)
  }

  private mutating func dispatch(_ byte: UInt8, _ sink: (JSONEvent, JSONContext) -> Bool) throws
    -> Bool
  {
    switch byte {
    case 0x20, 0x09, 0x0D:
      return true

    case 0x0A:
      if expect == .afterTop { sawNewline = true }

      return true

    default:
      break
    }

    switch expect {
    case .afterTop:
      guard mode == .lines else { throw fail("unexpected data after the JSON value") }
      guard sawNewline else { throw fail("a JSON Lines value must start on a new line") }

      expect = .value
      return try dispatch(byte, sink)

    case .value:
      return try beginValue(byte, allowEnd: false, sink)

    case .valueOrEnd:
      return try beginValue(byte, allowEnd: true, sink)

    case .keyOrEnd:
      if byte == UInt8(ascii: "}") { return try close(isObject: true, sink) }

      return try beginKey(byte)

    case .key:
      return try beginKey(byte)

    case .colon:
      guard byte == UInt8(ascii: ":") else { throw fail("expected a colon after the key") }

      expect = .value
      return true

    case .commaOrEnd:
      let inObject = stack.last == true

      switch byte {
      case UInt8(ascii: ","):
        expect = inObject ? .key : .value
        return true

      case UInt8(ascii: "}") where inObject:
        return try close(isObject: true, sink)

      case UInt8(ascii: "]") where !inObject:
        return try close(isObject: false, sink)

      default:
        throw fail(inObject ? "expected a comma or } here" : "expected a comma or ] here")
      }
    }
  }

  private mutating func beginKey(_ byte: UInt8) throws -> Bool {
    guard byte == UInt8(ascii: "\"") else { throw fail("expected a key in quotes") }

    startString(isKey: true)
    return true
  }

  private mutating func beginValue(
    _ byte: UInt8, allowEnd: Bool, _ sink: (JSONEvent, JSONContext) -> Bool
  ) throws -> Bool {
    switch byte {
    case UInt8(ascii: "{"):
      try push(isObject: true, byte)
      expect = .keyOrEnd
      return emit(.beginObject, start: offset, end: offset + 1, sink)

    case UInt8(ascii: "["):
      try push(isObject: false, byte)
      expect = .valueOrEnd
      return emit(.beginArray, start: offset, end: offset + 1, sink)

    case UInt8(ascii: "]") where allowEnd:
      return try close(isObject: false, sink)

    case UInt8(ascii: "\""):
      startString(isKey: false)
      return true

    case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
      lex = .number
      tokenStart = offset
      numberTooLong = false
      buffer = [byte]
      return true

    case UInt8(ascii: "t"), UInt8(ascii: "f"), UInt8(ascii: "n"):
      lex = .word
      tokenStart = offset
      buffer = [byte]
      return true

    default:
      throw fail("unexpected character")
    }
  }

  private mutating func push(isObject: Bool, _ byte: UInt8) throws {
    guard stack.count < Self.maxDepth else {
      throw fail("nested more than \(Self.maxDepth) levels deep")
    }

    stack.append(isObject)

    if let captureAt, stack.count == captureAt {
      capturing = true
      captureOverflow = false
      captured = [byte]
    }
  }

  private mutating func close(
    isObject: Bool, _ sink: (JSONEvent, JSONContext) -> Bool
  ) throws -> Bool {
    guard stack.last == isObject else { throw fail("mismatched bracket") }

    stack.removeLast()

    let proceed = emit(
      isObject ? .endObject : .endArray, start: offset, end: offset + 1, sink)

    if let captureAt, capturing, stack.count < captureAt { capturing = false }

    completeValue()
    return proceed
  }

  private mutating func completeValue() {
    if stack.isEmpty {
      valueCount += 1
      expect = .afterTop
      sawNewline = false
    } else {
      expect = .commaOrEnd
    }
  }

  private mutating func emit(
    _ event: JSONEvent, start: Int, end: Int, _ sink: (JSONEvent, JSONContext) -> Bool
  ) -> Bool {
    sink(
      event,
      JSONContext(
        depth: stack.count, valueCount: valueCount, start: start, end: end, captured: captured,
        captureOverflow: captureOverflow, truncatedValues: truncatedValues))
  }

  private mutating func appendCaptured(_ byte: UInt8) {
    if captured.count < JSONRule.maxElementBytes {
      captured.append(byte)
    } else {
      captureOverflow = true
    }
  }

  // MARK: Strings

  private mutating func startString(isKey: Bool) {
    lex = .string(isKey: isKey)
    tokenStart = offset
    limit = isKey ? Self.maxKeyBytes : JSONRule.maxStringBytes
    buffer.removeAll(keepingCapacity: true)
    truncated = false
    highSurrogate = nil
  }

  private mutating func stringByte(
    _ byte: UInt8, isKey: Bool, _ sink: (JSONEvent, JSONContext) -> Bool
  ) throws -> Bool {
    switch byte {
    case UInt8(ascii: "\""):
      flushSurrogate()
      lex = .none

      let value = finishedString()
      tokenEnd = offset + 1

      if isKey {
        expect = .colon
        return emit(.key(value), start: tokenStart, end: tokenEnd, sink)
      }

      let proceed = emit(.string(value), start: tokenStart, end: tokenEnd, sink)
      completeValue()
      return proceed

    case UInt8(ascii: "\\"):
      lex = .escape(isKey: isKey)
      return true

    case 0..<0x20:
      throw fail("a string holds a raw control character")

    default:
      flushSurrogate()
      append(byte)
      return true
    }
  }

  private mutating func escapeByte(_ byte: UInt8, isKey: Bool) throws -> Bool {
    let simple: UInt8

    switch byte {
    case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): simple = byte
    case UInt8(ascii: "b"): simple = 0x08
    case UInt8(ascii: "f"): simple = 0x0C
    case UInt8(ascii: "n"): simple = 0x0A
    case UInt8(ascii: "r"): simple = 0x0D
    case UInt8(ascii: "t"): simple = 0x09

    case UInt8(ascii: "u"):
      lex = .unicode(isKey: isKey, digits: 0, value: 0)
      return true

    default:
      throw fail("a string holds an unknown escape")
    }

    flushSurrogate()
    append(simple)
    lex = .string(isKey: isKey)
    return true
  }

  private mutating func unicodeByte(
    _ byte: UInt8, isKey: Bool, digits: Int, value: UInt32
  ) throws -> Bool {
    guard let digit = Self.hexValue(byte) else { throw fail("a \\u escape needs four hex digits") }

    let next = value << 4 | digit

    guard digits == 3 else {
      lex = .unicode(isKey: isKey, digits: digits + 1, value: next)
      return true
    }

    lex = .string(isKey: isKey)

    switch next {
    case 0xD800...0xDBFF:
      flushSurrogate()
      highSurrogate = next

    case 0xDC00...0xDFFF:
      if let high = highSurrogate {
        highSurrogate = nil
        appendScalar(0x10000 + ((high - 0xD800) << 10) + (next - 0xDC00))
      } else {
        appendScalar(0xFFFD)
      }

    default:
      flushSurrogate()
      appendScalar(next)
    }

    return true
  }

  private mutating func flushSurrogate() {
    guard highSurrogate != nil else { return }

    highSurrogate = nil
    appendScalar(0xFFFD)
  }

  private mutating func append(_ byte: UInt8) {
    if buffer.count < limit {
      buffer.append(byte)
    } else {
      truncated = true
    }
  }

  private mutating func appendScalar(_ scalar: UInt32) {
    if scalar < 0x80 {
      append(UInt8(scalar))
    } else if scalar < 0x800 {
      append(UInt8(0xC0 | scalar >> 6))
      append(UInt8(0x80 | scalar & 0x3F))
    } else if scalar < 0x10000 {
      append(UInt8(0xE0 | scalar >> 12))
      append(UInt8(0x80 | scalar >> 6 & 0x3F))
      append(UInt8(0x80 | scalar & 0x3F))
    } else {
      append(UInt8(0xF0 | scalar >> 18))
      append(UInt8(0x80 | scalar >> 12 & 0x3F))
      append(UInt8(0x80 | scalar >> 6 & 0x3F))
      append(UInt8(0x80 | scalar & 0x3F))
    }
  }

  /// The string read so far. A string cut at the cap loses a character the cut left half done.
  private mutating func finishedString() -> [UInt8] {
    if truncated {
      truncatedValues += 1

      while let last = buffer.last, last & 0xC0 == 0x80 {
        buffer.removeLast()
      }

      if let last = buffer.last, last >= 0xC0 { buffer.removeLast() }
    }

    let value = buffer
    buffer.removeAll(keepingCapacity: true)
    return value
  }

  // MARK: Numbers and words

  private mutating func finishNumber(_ sink: (JSONEvent, JSONContext) -> Bool) throws -> Bool {
    if numberTooLong {
      numberTooLong = false
      truncatedValues += 1
      lex = .none
      tokenEnd = offset
      buffer.removeAll(keepingCapacity: true)

      let proceed = emit(
        .string(Array(JSONRule.tooLargeNote.utf8)), start: tokenStart, end: tokenEnd, sink)
      completeValue()
      return proceed
    }

    guard Self.isValidNumber(buffer) else { throw fail("this is not a valid number") }

    lex = .none
    tokenEnd = offset

    let proceed = emit(.number(buffer), start: tokenStart, end: tokenEnd, sink)
    buffer.removeAll(keepingCapacity: true)
    completeValue()
    return proceed
  }

  private mutating func finishWord(_ sink: (JSONEvent, JSONContext) -> Bool) throws -> Bool {
    let event: JSONEvent

    switch String(decoding: buffer, as: UTF8.self) {
    case "true": event = .bool(true)
    case "false": event = .bool(false)
    case "null": event = .null
    default: throw fail("unexpected text")
    }

    lex = .none
    tokenEnd = offset
    buffer.removeAll(keepingCapacity: true)

    let proceed = emit(event, start: tokenStart, end: tokenEnd, sink)
    completeValue()
    return proceed
  }

  private static func isNumberByte(_ byte: UInt8) -> Bool {
    switch byte {
    case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "+"),
      UInt8(ascii: "."), UInt8(ascii: "e"), UInt8(ascii: "E"):
      return true

    default:
      return false
    }
  }

  /// RFC 8259: an optional minus, an integer part with no leading zero, an optional fraction, and an
  /// optional exponent.
  static func isValidNumber(_ bytes: [UInt8]) -> Bool {
    var index = 0
    let count = bytes.count

    func digits() -> Int {
      let begin = index

      while index < count, bytes[index] >= 0x30, bytes[index] <= 0x39 {
        index += 1
      }

      return index - begin
    }

    if index < count, bytes[index] == UInt8(ascii: "-") { index += 1 }

    guard index < count else { return false }

    if bytes[index] == UInt8(ascii: "0") {
      index += 1
    } else if digits() == 0 {
      return false
    }

    if index < count, bytes[index] == UInt8(ascii: ".") {
      index += 1

      guard digits() > 0 else { return false }
    }

    if index < count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
      index += 1

      if index < count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") {
        index += 1
      }

      guard digits() > 0 else { return false }
    }

    return index == count
  }

  private static func hexValue(_ byte: UInt8) -> UInt32? {
    switch byte {
    case UInt8(ascii: "0")...UInt8(ascii: "9"): return UInt32(byte - 0x30)
    case UInt8(ascii: "a")...UInt8(ascii: "f"): return UInt32(byte - 0x61 + 10)
    case UInt8(ascii: "A")...UInt8(ascii: "F"): return UInt32(byte - 0x41 + 10)
    default: return nil
    }
  }

  private func fail(_ reason: String) -> JSONSyntaxError {
    JSONSyntaxError(reason: reason, line: line, column: offset - lineStart + 1)
  }
}
