import Foundation

/// The text encodings the CSV reader understands.
enum CSVEncoding: Sendable, Equatable {
  case utf8
  case utf16LittleEndian
  case utf16BigEndian
  case windows1252
}

/// The one rule that picks a CSV file's text encoding, delimiter, and header row. The same file
/// always gets the same answer, since the rule reads only the file's own bytes and name.
///
/// Encoding:
/// 1. A byte-order mark wins. UTF-8 is EF BB BF. UTF-16 is FF FE for little endian and FE FF for
///    big endian. UTF-32 is not supported.
/// 2. Otherwise the first 64 KiB decides. If it is valid UTF-8, the file is UTF-8. A multi-byte
///    sequence cut by the end of the sample does not count against it, unless the sample is the
///    whole file.
/// 3. Otherwise the file is Windows-1252.
///
/// Bytes past the sample that are not valid UTF-8 in a UTF-8 file show as U+FFFD.
///
/// Delimiter:
/// 1. A `.tsv` or `.tab` name means tab.
/// 2. Otherwise each of `,` `;` tab `|` is tried on the first 64 KiB, with quotes honored. The
///    candidate that gives the most rows the same field count, above one field, wins.
/// 3. A tie goes to the earlier candidate in that list, so comma wins. A file with no candidate
///    above one field is read with comma.
///
/// Header:
/// 1. The first row is the header unless a cell in it is a number.
/// 2. A header cell that is empty leaves its column named by position.
/// 3. A file whose first row holds a number has no header, and every column is named by position.
enum CSVRule {
  static let sampleSize = 64 * 1024

  static func encoding(of sample: [UInt8], isWholeFile: Bool) -> (encoding: CSVEncoding, bom: Int) {
    if sample.starts(with: [0xEF, 0xBB, 0xBF]) { return (.utf8, 3) }
    if sample.starts(with: [0xFF, 0xFE]) { return (.utf16LittleEndian, 2) }
    if sample.starts(with: [0xFE, 0xFF]) { return (.utf16BigEndian, 2) }

    var checked = sample[...]

    if !isWholeFile {
      checked = checked.dropLast(incompleteTail(of: sample))
    }

    return (String(validating: checked, as: UTF8.self) != nil ? .utf8 : .windows1252, 0)
  }

  /// The number of bytes at the end of `bytes` that start a UTF-8 sequence the sample cuts short.
  private static func incompleteTail(of bytes: [UInt8]) -> Int {
    for back in 1...min(3, bytes.count) {
      let byte = bytes[bytes.count - back]

      if byte & 0xC0 == 0x80 { continue }

      let needed =
        byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
      return needed > back ? back : 0
    }

    return 0
  }

  static let candidates: [UInt8] = [UInt8(ascii: ","), UInt8(ascii: ";"), 0x09, UInt8(ascii: "|")]

  static func delimiter(in sample: [UInt8], fileExtension: String) -> UInt8 {
    if ["tsv", "tab"].contains(fileExtension.lowercased()) { return 0x09 }

    var best = candidates[0]
    var bestScore = 0

    for candidate in candidates {
      let score = consistency(of: candidate, in: sample)

      if score > bestScore {
        best = candidate
        bestScore = score
      }
    }

    return best
  }

  /// The number of rows that share the most common field count, or zero when that count is one.
  /// The last row of the sample is left out, since the sample may cut it.
  private static func consistency(of delimiter: UInt8, in sample: [UInt8]) -> Int {
    var parser = CSVParser(delimiter: delimiter)
    var counts: [Int: Int] = [:]
    var rows = 0

    parser.feed(sample[...]) { _, ends in
      rows += 1
      counts[ends.count, default: 0] += 1
      return rows < 200
    }

    guard let (fields, matching) = counts.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }),
      fields > 1
    else { return 0 }

    return matching
  }

  /// A header unless a cell is a number.
  static func isHeader(_ firstRow: [String]) -> Bool {
    !firstRow.contains { isNumber($0) }
  }

  /// A plain decimal number, with an optional sign, fraction, and exponent. Words that `Double`
  /// reads, such as `nan` and `inf`, are not numbers here.
  static func isNumber(_ text: String) -> Bool {
    number(text) != nil
  }

  static func number(_ text: String) -> Double? {
    let bytes = Array(text.utf8)
    var index = 0

    while index < bytes.count, bytes[index] == 0x20 { index += 1 }

    let start = index

    if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") {
      index += 1
    }

    var digits = 0
    while index < bytes.count, isDigit(bytes[index]) {
      index += 1
      digits += 1
    }

    if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
      index += 1
      while index < bytes.count, isDigit(bytes[index]) {
        index += 1
        digits += 1
      }
    }

    guard digits > 0 else { return nil }

    if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
      index += 1

      if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-")
      {
        index += 1
      }

      var exponent = 0
      while index < bytes.count, isDigit(bytes[index]) {
        index += 1
        exponent += 1
      }

      guard exponent > 0 else { return nil }
    }

    let end = index
    while index < bytes.count, bytes[index] == 0x20 { index += 1 }

    guard index == bytes.count else { return nil }

    return Double(String(decoding: bytes[start..<end], as: UTF8.self))
  }

  private static func isDigit(_ byte: UInt8) -> Bool {
    byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
  }
}
