import XCTest

@testable import BrowserModel

final class AppHandoffTests: XCTestCase {
  /// Catches a page or refused scheme that could reach an app. Only a scheme that is neither a
  /// page nor refused may hand off.
  func testPageAndRefusedSchemesNeverHandOff() {
    for scheme in ["http", "HTTPS", "about", "blob", "data", "file", "javascript", "", "unknown"] {
      XCTAssertFalse(AppHandoff.mayHandOff(scheme: scheme), scheme)
    }

    for scheme in ["mailto", "ssh", "tel", "slack", "vnc", "x-apple.systempreferences"] {
      XCTAssertTrue(AppHandoff.mayHandOff(scheme: scheme), scheme)
    }
  }

  /// Catches a question skipped for an app that runs code, and `mailto:` that asks. Only `mailto:`
  /// opens without a question, in any letter case.
  func testOnlyMailtoOpensWithoutAsking() throws {
    XCTAssertTrue(AppHandoff.opensWithoutAsking(try XCTUnwrap(URL(string: "mailto:a@example.com"))))
    XCTAssertTrue(AppHandoff.opensWithoutAsking(try XCTUnwrap(URL(string: "MAILTO:a@example.com"))))
    XCTAssertFalse(AppHandoff.opensWithoutAsking(try XCTUnwrap(URL(string: "ssh://host"))))
    XCTAssertFalse(AppHandoff.opensWithoutAsking(try XCTUnwrap(URL(string: "tel:1"))))
  }

  /// Catches a question that does not name both the app and the address, and one that lets a long
  /// address push the app's name out of sight.
  func testTheQuestionNamesTheAppAndTheAddress() throws {
    let url = try XCTUnwrap(URL(string: "ssh://host.example"))
    let question = AppHandoff.question(appName: "Terminal", url: url)

    XCTAssertEqual(question.title, "Open Terminal?")
    XCTAssertTrue(question.detail.contains("ssh://host.example"))
    XCTAssertTrue(question.detail.contains("Terminal"))

    let long = try XCTUnwrap(
      URL(string: "ssh://host.example/" + String(repeating: "a", count: 500)))

    XCTAssertLessThan(AppHandoff.question(appName: "Terminal", url: long).detail.count, 400)
  }
}
