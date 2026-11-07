import XCTest

@testable import BrowserModel

final class DownloadNameTests: XCTestCase {
  /// Catches a page-chosen name that climbs out of the folder, hides the file, disguises the
  /// extension, or leaves no name at all. Expected values are written by hand.
  func testSanitizeTable() {
    let long = String(repeating: "a", count: 300)
    let cases: [(name: String, input: String, expected: String)] = [
      ("plain", "report.pdf", "report.pdf"),
      ("unicode", "résumé 履歴書.pdf", "résumé 履歴書.pdf"),
      ("slash", "a/b.txt", "a_b.txt"),
      ("backslash", "a\\b.txt", "a_b.txt"),
      ("climb", "../../etc/passwd", "_.._etc_passwd"),
      ("only dots", "..", "download"),
      ("one dot", ".", "download"),
      ("leading dot", ".bashrc", "bashrc"),
      ("leading dots and space", " .. .profile", "profile"),
      ("rtl override", "invoice\u{202E}fdp.exe", "invoicefdp.exe"),
      ("isolates", "\u{2066}a\u{2069}.txt", "a.txt"),
      ("marks", "a\u{200E}b\u{200F}c\u{061C}.txt", "abc.txt"),
      ("controls", "a\u{0}b\nc\td\u{7F}.txt", "abcd.txt"),
      ("trailing dots", "name...", "name"),
      ("trailing spaces and dots", "name. . ", "name"),
      ("reserved", "a:b*c?d\"e<f>g|h.txt", "a_b_c_d_e_f_g_h.txt"),
      ("empty", "", "download"),
      ("only controls", "\u{1}\u{2}", "download"),
      ("only separators", "///", "___"),
      ("only bidi", "\u{202E}\u{202D}", "download"),
      ("long with extension", long + ".pdf", String(repeating: "a", count: 196) + ".pdf"),
      ("long no extension", long, String(repeating: "a", count: 200)),
      (
        "long with huge tail", "a." + String(repeating: "b", count: 300),
        "a." + String(repeating: "b", count: 198)
      ),
      ("zero width space", "a\u{200B}b.txt", "ab.txt"),
      ("zero width joiners", "a\u{200C}\u{200D}b.txt", "ab.txt"),
      ("byte order mark", "\u{FEFF}x.txt", "x.txt"),
      ("word joiner", "a\u{2060}b.txt", "ab.txt"),
      ("soft hyphen", "a\u{00AD}b.txt", "ab.txt"),
      ("line and paragraph separators", "a\u{2028}b\u{2029}c.txt", "abc.txt"),
      ("hangul fillers", "a\u{3164}\u{115F}\u{1160}\u{FFA0}b.txt", "ab.txt"),
      ("braille blank", "a\u{2800}b.txt", "ab.txt"),
      ("only invisible", "\u{200B}\u{FEFF}\u{3164}", "download"),
      ("long run of spaces", "invoice.pdf          .app", "invoice.pdf .app"),
      ("no breaking spaces", "a\u{00A0}\u{00A0}\u{2003}b.txt", "a b.txt"),
      ("ideographic space", "a\u{3000}b.txt", "a b.txt"),
      ("spaces made by dropped marks", "a \u{200B} b.txt", "a b.txt"),
      ("hidden extension kept", ".gitignore", "gitignore"),
      (
        "multi-byte cut", String(repeating: "界", count: 100) + ".txt",
        String(repeating: "界", count: 65) + ".txt"
      ),
    ]

    for item in cases {
      XCTAssertEqual(DownloadName.sanitize(item.input), item.expected, item.name)
    }
  }

  /// Catches a cleaned name that still is not a legal name: every result is non-empty, within the
  /// byte bound, and free of separators.
  func testEveryResultIsASafeName() {
    let inputs = [
      "", ".", "..", "/", "\u{202E}", "a/../b", String(repeating: "x.", count: 400),
      String(repeating: "界", count: 400), " ", "...", "a\u{0}", "\u{FEFF}x",
    ]

    for input in inputs {
      let name = DownloadName.sanitize(input)

      XCTAssertFalse(name.isEmpty, input)
      XCTAssertLessThanOrEqual(name.utf8.count, DownloadName.maximumBytes, input)
      XCTAssertFalse(name.contains("/"), input)
      XCTAssertFalse(name.hasPrefix("."), input)
      XCTAssertFalse(name.hasSuffix("."), input)
    }
  }

  func testNumberingGoesBeforeTheExtension() {
    XCTAssertEqual(DownloadName.numbered("a.pdf", attempt: 1), "a.pdf")
    XCTAssertEqual(DownloadName.numbered("a.pdf", attempt: 2), "a 2.pdf")
    XCTAssertEqual(DownloadName.numbered("a.tar.gz", attempt: 3), "a.tar 3.gz")
    XCTAssertEqual(DownloadName.numbered("README", attempt: 2), "README 2")
    XCTAssertEqual(DownloadName.numbered("name.", attempt: 2), "name. 2")
  }

  func testRunningLabelCleansAPageChosenTitle() {
    XCTAssertEqual(
      RunningLabel.clean("  A \u{202E}title\n\twith  gaps ", fallback: "Tab"), "A title with gaps")
    XCTAssertEqual(RunningLabel.clean("\u{202E}\n", fallback: "Tab"), "Tab")
    XCTAssertEqual(
      RunningLabel.clean(String(repeating: "x", count: 200), fallback: "Tab"),
      String(repeating: "x", count: 80) + "\u{2026}")
  }

  func testDownloadMessagesNameTheFile() {
    XCTAssertEqual(DownloadMessage.finished("a.pdf"), "Downloaded a.pdf.")
    XCTAssertEqual(
      DownloadMessage.failed("a.pdf", reason: "The network connection was lost"),
      "Could not download a.pdf. The network connection was lost.")
    XCTAssertEqual(
      DownloadMessage.failed("a.pdf", reason: "Lost."), "Could not download a.pdf. Lost.")
  }
}
