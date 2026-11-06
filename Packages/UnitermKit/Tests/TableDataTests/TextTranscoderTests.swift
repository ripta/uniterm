import XCTest

@testable import TableData

/// The transcoder carries state across chunks: an odd UTF-16 byte, and a high surrogate that waits
/// for its low half. The expected bytes come from the text itself, not from the transcoder.
final class TextTranscoderTests: XCTestCase {
  private let text = "plain, caf\u{E9} \u{20AC}5 \u{1F600}\u{1D11E} \u{4E2D}\u{6587}\n1,2\r\n"

  private func encoded(_ encoding: CSVEncoding) -> [UInt8] {
    switch encoding {
    case .utf8, .windows1252:
      return Array(text.utf8)

    case .utf16LittleEndian:
      return text.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }

    case .utf16BigEndian:
      return text.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
    }
  }

  private func convert(_ input: [UInt8], _ encoding: CSVEncoding, cuts: [Int]) -> [UInt8] {
    var transcoder = TextTranscoder(encoding)
    var output: [UInt8] = []
    var start = 0

    for cut in cuts + [input.count] {
      transcoder.convert(
        input[start..<cut], final: cut == input.count, into: &output)
      start = cut
    }

    return output
  }

  /// Catches a carry that loses or doubles a byte. UTF-16 in both byte orders and UTF-8 come out
  /// as the text's own UTF-8, split at every single offset, which includes the middle of every
  /// surrogate pair and every odd offset.
  func testEverySingleSplitGivesTheWholeResult() {
    for encoding in [CSVEncoding.utf8, .utf16LittleEndian, .utf16BigEndian] {
      let input = encoded(encoding)

      for cut in 0...input.count {
        XCTAssertEqual(
          convert(input, encoding, cuts: [cut]), Array(text.utf8), "\(encoding) at \(cut)")
      }
    }
  }

  /// Catches a carry that breaks with several small chunks: random splits, down to one byte at a
  /// time.
  func testRandomSplitsGiveTheWholeResult() {
    var random = SplitMix64(seed: 0xC0FFEE)

    for encoding in [CSVEncoding.utf8, .utf16LittleEndian, .utf16BigEndian, .windows1252] {
      let input = encoded(encoding)

      for _ in 0..<200 {
        var cuts = Set<Int>()
        for _ in 0..<(1 + Int(random.next() % 12)) {
          cuts.insert(Int(random.next() % UInt64(input.count + 1)))
        }

        let whole = convert(input, encoding, cuts: [])

        XCTAssertEqual(convert(input, encoding, cuts: cuts.sorted()), whole, "\(encoding)")
      }

      XCTAssertEqual(
        convert(input, encoding, cuts: Array(1..<input.count)), convert(input, encoding, cuts: []))
    }
  }

  /// Catches a file that ends in the middle of a character: the last unit becomes U+FFFD, and
  /// nothing is dropped silently.
  func testATruncatedUTF16FileEndsWithAReplacementCharacter() {
    let highSurrogate: [UInt8] = [0x61, 0, 0x62, 0, 0x3D, 0xD8]
    let oddByte: [UInt8] = [0x61, 0, 0x62]

    XCTAssertEqual(
      convert(highSurrogate, .utf16LittleEndian, cuts: [3]), Array("ab\u{FFFD}".utf8))
    XCTAssertEqual(convert(oddByte, .utf16LittleEndian, cuts: [2]), Array("a\u{FFFD}".utf8))
  }
}
