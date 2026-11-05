import Foundation

/// Turns chunks of a file in one encoding into UTF-8, for a parser that reads only UTF-8. A chunk
/// may end in the middle of a character, and the transcoder carries what it needs to the next.
struct TextTranscoder {
  private let encoding: CSVEncoding
  private var carry: [UInt8] = []
  private var highSurrogate: UInt16?

  init(_ encoding: CSVEncoding) {
    self.encoding = encoding
  }

  /// Appends the UTF-8 for `chunk` to `output`. `final` marks the last chunk, which flushes a
  /// character the file cut short as U+FFFD.
  mutating func convert(_ chunk: ArraySlice<UInt8>, final: Bool, into output: inout [UInt8]) {
    switch encoding {
    case .utf8:
      output.append(contentsOf: chunk)

    case .windows1252:
      for byte in chunk {
        if byte < 0x80 {
          output.append(byte)
        } else {
          Self.append(Self.windows1252(byte), to: &output)
        }
      }

    case .utf16LittleEndian, .utf16BigEndian:
      convertUTF16(chunk, final: final, into: &output)
    }
  }

  private mutating func convertUTF16(
    _ chunk: ArraySlice<UInt8>, final: Bool, into output: inout [UInt8]
  ) {
    var bytes = carry
    bytes.append(contentsOf: chunk)
    carry = []

    let pairs = bytes.count / 2

    for index in 0..<pairs {
      let first = UInt16(bytes[index * 2])
      let second = UInt16(bytes[index * 2 + 1])
      let unit = encoding == .utf16LittleEndian ? first | second << 8 : first << 8 | second

      if let high = highSurrogate {
        highSurrogate = nil

        if (0xDC00...0xDFFF).contains(unit) {
          let scalar = 0x10000 + (UInt32(high) - 0xD800) << 10 + (UInt32(unit) - 0xDC00)
          Self.append(Unicode.Scalar(scalar) ?? "\u{FFFD}", to: &output)
          continue
        }

        Self.append("\u{FFFD}", to: &output)
      }

      if (0xD800...0xDBFF).contains(unit) {
        highSurrogate = unit
      } else if (0xDC00...0xDFFF).contains(unit) {
        Self.append("\u{FFFD}", to: &output)
      } else {
        Self.append(Unicode.Scalar(UInt32(unit)) ?? "\u{FFFD}", to: &output)
      }
    }

    if bytes.count % 2 == 1 {
      carry = [bytes[bytes.count - 1]]
    }

    if final {
      if highSurrogate != nil || !carry.isEmpty {
        Self.append("\u{FFFD}", to: &output)
      }

      highSurrogate = nil
      carry = []
    }
  }

  private static func append(_ scalar: Unicode.Scalar, to output: inout [UInt8]) {
    output.append(contentsOf: String(Character(scalar)).utf8)
  }

  /// The code point of a Windows-1252 byte at 0x80 or above. The five bytes the code page leaves
  /// undefined map to the control character of the same value, as browsers read them.
  private static func windows1252(_ byte: UInt8) -> Unicode.Scalar {
    guard byte < 0xA0 else { return Unicode.Scalar(byte) }

    let table: [UInt32] = [
      0x20AC, 0x81, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
      0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x8D, 0x017D, 0x8F,
      0x90, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
      0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x9D, 0x017E, 0x0178,
    ]

    return Unicode.Scalar(table[Int(byte) - 0x80]) ?? "\u{FFFD}"
  }
}
