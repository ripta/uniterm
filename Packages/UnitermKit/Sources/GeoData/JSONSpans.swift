import Foundation

/// Why a JSON document could not be read for patching.
public struct JSONSpanError: Error, Equatable, Sendable {
  public let offset: Int
  public let reason: String
}

/// One member of a JSON object: its key, and where its key and value sit in the bytes.
struct JSONMember: Equatable {
  let key: String

  /// From the key's opening quote to its closing quote, inclusive.
  let keySpan: Range<Int>
  let valueSpan: Range<Int>
}

/// Reads where things are in a JSON document without building it.
///
/// The patcher needs the byte offsets of a few values, not a tree of the whole file, so a reader
/// asks for one object's members or one array's elements and skips everything inside them.
/// Skipping still checks the syntax, so a span is only ever reported over valid JSON. Nesting is
/// bounded, so a hostile file cannot exhaust the stack.
struct JSONSpans {
  static let maximumDepth = 512

  let bytes: [UInt8]

  init(_ bytes: [UInt8]) {
    self.bytes = bytes
  }

  /// The span of the document's one top-level value, after any byte order mark and whitespace.
  func root() throws -> Range<Int> {
    var at = 0

    if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { at = 3 }

    at = skipWhitespace(from: at)
    let span = try skipValue(at: at, depth: 0)
    let rest = skipWhitespace(from: span.upperBound)

    guard rest == bytes.count else { throw fail(rest, "text follows the document") }

    return span
  }

  /// The members of the object whose span is `span`, in file order.
  func members(of span: Range<Int>) throws -> [JSONMember] {
    guard span.lowerBound < bytes.count, bytes[span.lowerBound] == UInt8(ascii: "{") else {
      throw fail(span.lowerBound, "expected an object")
    }

    var members: [JSONMember] = []
    var at = skipWhitespace(from: span.lowerBound + 1)

    if at < bytes.count, bytes[at] == UInt8(ascii: "}") { return [] }

    while true {
      let (key, keySpan) = try string(at: at)
      at = skipWhitespace(from: keySpan.upperBound)

      guard at < bytes.count, bytes[at] == UInt8(ascii: ":") else { throw fail(at, "expected :") }

      at = skipWhitespace(from: at + 1)
      let value = try skipValue(at: at, depth: 1)
      members.append(JSONMember(key: key, keySpan: keySpan, valueSpan: value))
      at = skipWhitespace(from: value.upperBound)

      guard at < bytes.count else { throw fail(at, "the object is not closed") }

      if bytes[at] == UInt8(ascii: "}") { return members }

      guard bytes[at] == UInt8(ascii: ",") else { throw fail(at, "expected , or }") }

      at = skipWhitespace(from: at + 1)
    }
  }

  /// The spans of the elements of the array whose span is `span`, in file order.
  func elements(of span: Range<Int>) throws -> [Range<Int>] {
    guard span.lowerBound < bytes.count, bytes[span.lowerBound] == UInt8(ascii: "[") else {
      throw fail(span.lowerBound, "expected an array")
    }

    var elements: [Range<Int>] = []
    var at = skipWhitespace(from: span.lowerBound + 1)

    if at < bytes.count, bytes[at] == UInt8(ascii: "]") { return [] }

    while true {
      let value = try skipValue(at: at, depth: 1)
      elements.append(value)
      at = skipWhitespace(from: value.upperBound)

      guard at < bytes.count else { throw fail(at, "the array is not closed") }

      if bytes[at] == UInt8(ascii: "]") { return elements }

      guard bytes[at] == UInt8(ascii: ",") else { throw fail(at, "expected , or ]") }

      at = skipWhitespace(from: at + 1)
    }
  }

  /// The string value at `span`, or nil when the value there is not a string.
  func stringValue(_ span: Range<Int>) -> String? {
    guard span.lowerBound < bytes.count, bytes[span.lowerBound] == UInt8(ascii: "\"") else {
      return nil
    }

    return try? string(at: span.lowerBound).0
  }

  /// True when the value at `span` is the literal `null`.
  func isNull(_ span: Range<Int>) -> Bool {
    Array(bytes[span]) == Array("null".utf8)
  }

  /// The run of whitespace between two offsets, as text to copy into an insertion.
  func text(_ span: Range<Int>) -> [UInt8] {
    Array(bytes[span])
  }

  // MARK: Scanning

  func skipWhitespace(from start: Int) -> Int {
    var at = start

    while at < bytes.count {
      switch bytes[at] {
      case 0x20, 0x09, 0x0A, 0x0D: at += 1
      default: return at
      }
    }

    return at
  }

  private func skipValue(at start: Int, depth: Int) throws -> Range<Int> {
    guard depth <= Self.maximumDepth else { throw fail(start, "the document nests too deeply") }

    guard start < bytes.count else { throw fail(start, "expected a value") }

    switch bytes[start] {
    case UInt8(ascii: "{"):
      var at = skipWhitespace(from: start + 1)

      if at < bytes.count, bytes[at] == UInt8(ascii: "}") { return start..<(at + 1) }

      while true {
        at = try string(at: at).1.upperBound
        at = skipWhitespace(from: at)

        guard at < bytes.count, bytes[at] == UInt8(ascii: ":") else { throw fail(at, "expected :") }

        at = try skipValue(at: skipWhitespace(from: at + 1), depth: depth + 1).upperBound
        at = skipWhitespace(from: at)

        guard at < bytes.count else { throw fail(at, "the object is not closed") }

        if bytes[at] == UInt8(ascii: "}") { return start..<(at + 1) }

        guard bytes[at] == UInt8(ascii: ",") else { throw fail(at, "expected , or }") }

        at = skipWhitespace(from: at + 1)
      }

    case UInt8(ascii: "["):
      var at = skipWhitespace(from: start + 1)

      if at < bytes.count, bytes[at] == UInt8(ascii: "]") { return start..<(at + 1) }

      while true {
        at = try skipValue(at: at, depth: depth + 1).upperBound
        at = skipWhitespace(from: at)

        guard at < bytes.count else { throw fail(at, "the array is not closed") }

        if bytes[at] == UInt8(ascii: "]") { return start..<(at + 1) }

        guard bytes[at] == UInt8(ascii: ",") else { throw fail(at, "expected , or ]") }

        at = skipWhitespace(from: at + 1)
      }

    case UInt8(ascii: "\""):
      return try string(at: start).1

    case UInt8(ascii: "t"):
      return try literal("true", at: start)

    case UInt8(ascii: "f"):
      return try literal("false", at: start)

    case UInt8(ascii: "n"):
      return try literal("null", at: start)

    default:
      return try number(at: start)
    }
  }

  private func literal(_ word: String, at start: Int) throws -> Range<Int> {
    let end = start + word.utf8.count

    guard end <= bytes.count, Array(bytes[start..<end]) == Array(word.utf8) else {
      throw fail(start, "expected \(word)")
    }

    return start..<end
  }

  private func number(at start: Int) throws -> Range<Int> {
    var at = start

    func digits() -> Int {
      let from = at

      while at < bytes.count, bytes[at] >= 0x30, bytes[at] <= 0x39 { at += 1 }

      return at - from
    }

    if at < bytes.count, bytes[at] == UInt8(ascii: "-") { at += 1 }

    guard digits() > 0 else { throw fail(start, "expected a value") }

    if at < bytes.count, bytes[at] == UInt8(ascii: ".") {
      at += 1

      guard digits() > 0 else { throw fail(at, "expected a digit") }
    }

    if at < bytes.count, bytes[at] == UInt8(ascii: "e") || bytes[at] == UInt8(ascii: "E") {
      at += 1

      if at < bytes.count, bytes[at] == UInt8(ascii: "+") || bytes[at] == UInt8(ascii: "-") {
        at += 1
      }

      guard digits() > 0 else { throw fail(at, "expected a digit") }
    }

    return start..<at
  }

  /// Reads the string whose opening quote is at `start`, and returns its text and its span.
  private func string(at start: Int) throws -> (String, Range<Int>) {
    guard start < bytes.count, bytes[start] == UInt8(ascii: "\"") else {
      throw fail(start, "expected a string")
    }

    var at = start + 1
    var scalars = String.UnicodeScalarView()
    var raw: [UInt8] = []

    func flush() throws {
      guard !raw.isEmpty else { return }

      guard let text = String(bytes: raw, encoding: .utf8) else {
        throw fail(at, "the string is not UTF-8")
      }

      scalars.append(contentsOf: text.unicodeScalars)
      raw.removeAll(keepingCapacity: true)
    }

    while at < bytes.count {
      let byte = bytes[at]

      switch byte {
      case UInt8(ascii: "\""):
        try flush()
        return (String(scalars), start..<(at + 1))

      case UInt8(ascii: "\\"):
        try flush()

        guard at + 1 < bytes.count else { throw fail(at, "the string is not closed") }

        let escape = bytes[at + 1]
        at += 2

        switch escape {
        case UInt8(ascii: "\""): scalars.append("\"")
        case UInt8(ascii: "\\"): scalars.append("\\")
        case UInt8(ascii: "/"): scalars.append("/")
        case UInt8(ascii: "b"): scalars.append("\u{08}")
        case UInt8(ascii: "f"): scalars.append("\u{0C}")
        case UInt8(ascii: "n"): scalars.append("\n")
        case UInt8(ascii: "r"): scalars.append("\r")
        case UInt8(ascii: "t"): scalars.append("\t")
        case UInt8(ascii: "u"):
          var unit = try hex(at: at)
          at += 4

          if (0xD800..<0xDC00).contains(unit), at + 1 < bytes.count,
            bytes[at] == UInt8(ascii: "\\"), bytes[at + 1] == UInt8(ascii: "u")
          {
            let low = try hex(at: at + 2)

            if (0xDC00..<0xE000).contains(low) {
              unit = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)
              at += 6
            }
          }

          scalars.append(Unicode.Scalar(unit) ?? "\u{FFFD}")

        default:
          throw fail(at - 1, "the string has an unknown escape")
        }

      case 0x00..<0x20:
        throw fail(at, "the string holds a control character")

      default:
        raw.append(byte)
        at += 1
      }
    }

    throw fail(at, "the string is not closed")
  }

  private func hex(at start: Int) throws -> UInt32 {
    guard start + 4 <= bytes.count,
      let value = UInt32(String(decoding: bytes[start..<(start + 4)], as: UTF8.self), radix: 16)
    else { throw fail(start, "the string has a bad \\u escape") }

    return value
  }

  private func fail(_ offset: Int, _ reason: String) -> JSONSpanError {
    JSONSpanError(offset: offset, reason: reason)
  }
}
