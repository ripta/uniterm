import XCTest

@testable import BrowserModel

/// Pins the rule that turns WebKit's secure-content flag into a warning. A regression is a warning
/// on a blank tab, or none on a page that loaded something insecure. It cannot prove that WebKit
/// sets the flag the way the rule assumes.
final class SecurityIndicatorTests: XCTestCase {
  func testTheWarningFollowsTheFlagForAnyLoadedPage() {
    let cases: [(url: String?, secure: Bool, warns: Bool)] = [
      ("https://example.com/", true, false),
      ("https://example.com/", false, true),
      ("http://example.com/", false, true),
      ("http://example.com/", true, true),
      ("HTTP://example.com/", true, true),
      ("http://127.0.0.1:8080/", false, true),
      ("blob:https://example.com/1", true, false),
      ("about:blank", false, false),
      ("about:blank", true, false),
      ("ABOUT:BLANK", false, false),
      ("about:blank#fragment", false, false),
      ("about:blank?q=1", false, false),
      ("about:srcdoc", false, true),
      (nil, false, false),
      (nil, true, false),
    ]

    for row in cases {
      let url = row.url.flatMap { URL(string: $0) }

      XCTAssertEqual(
        SecurityIndicator.warns(url: url, hasOnlySecureContent: row.secure), row.warns,
        "\(row.url ?? "nil") secure=\(row.secure)")
    }
  }
}
