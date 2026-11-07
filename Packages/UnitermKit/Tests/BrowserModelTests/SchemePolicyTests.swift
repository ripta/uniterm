import XCTest

@testable import BrowserModel

/// The rule for which schemes load, by source. Each case names a source and a URL and expects the
/// decision written out by hand from the settled rule, not read back from the policy.
final class SchemePolicyTests: XCTestCase {
  private func decision(
    _ text: String, _ source: NavigationSource, isMainFrame: Bool = true
  ) throws -> SchemeDecision {
    SchemePolicy.decide(try XCTUnwrap(URL(string: text)), source: source, isMainFrame: isMainFrame)
  }

  /// Catches a typed, restored, or controller source that loads more than the web: a `blob:` URL a
  /// controller could name, or a `data:` page a payload could carry. Each of the three sources
  /// takes the same strict rule, so a stored tab cannot reach what the address bar cannot.
  func testTypedRestoredAndControllerLoadsTakeOnlyTheWeb() throws {
    for source in [NavigationSource.typed, .restored, .controller] {
      for allowed in [
        "http://example.com", "https://example.com/a?b=c", "HTTPS://EXAMPLE.COM", "about:blank",
        "ABOUT:BLANK",
      ] {
        XCTAssertEqual(try decision(allowed, source), .allow, "\(allowed) from \(source)")
      }

      XCTAssertEqual(try decision("file:///etc/hosts", source), .refuse(.file))
      XCTAssertEqual(try decision("FILE:///etc/hosts", source), .refuse(.file))
      XCTAssertEqual(try decision("javascript:alert(1)", source), .refuse(.javascript))
      XCTAssertEqual(try decision("JavaScript:alert(1)", source), .refuse(.javascript))
      XCTAssertEqual(try decision("data:text/html,hi", source), .refuse(.data))
      XCTAssertEqual(
        try decision("blob:https://example.com/1234", source),
        .refuse(.unsupported(scheme: "blob")))
      XCTAssertEqual(
        try decision("about:config", source), .refuse(.unsupported(scheme: "about")))
      XCTAssertEqual(
        try decision("ftp://example.com", source), .refuse(.unsupported(scheme: "ftp")))
      XCTAssertEqual(
        try decision("mailto:a@example.com", source), .refuse(.unsupported(scheme: "mailto")))
    }
  }

  /// Catches a page that can load `file:` or `javascript:` from a link, or a top-level `data:`
  /// page. A page may open its own `blob:` URL, and a subframe may hold `data:` and `srcdoc`,
  /// since exports and previews are built from them.
  func testAPageMayOpenItsOwnBlobsAndDataSubframesButNeverFilesOrScriptOrDataPages() throws {
    XCTAssertEqual(try decision("https://example.com", .page), .allow)
    XCTAssertEqual(try decision("about:blank", .page), .allow)
    XCTAssertEqual(try decision("blob:https://example.com/1234", .page), .allow)

    XCTAssertEqual(try decision("data:text/html,hi", .page), .refuse(.data))
    XCTAssertEqual(try decision("data:text/html,hi", .page, isMainFrame: false), .allow)
    XCTAssertEqual(try decision("about:srcdoc", .page, isMainFrame: false), .allow)
    XCTAssertEqual(
      try decision("about:srcdoc", .page), .refuse(.unsupported(scheme: "about")))

    for isMainFrame in [true, false] {
      XCTAssertEqual(
        try decision("file:///etc/hosts", .page, isMainFrame: isMainFrame), .refuse(.file))
      XCTAssertEqual(
        try decision("javascript:alert(1)", .page, isMainFrame: isMainFrame),
        .refuse(.javascript))
    }
  }

  /// Catches a stored address that no restore would load being kept, which would leave a payload
  /// that shows a refusal at every launch.
  func testOnlyAddressesATypedLoadAcceptsAreLoadable() throws {
    XCTAssertTrue(SchemePolicy.isLoadable(try XCTUnwrap(URL(string: "https://example.com"))))
    XCTAssertTrue(SchemePolicy.isLoadable(try XCTUnwrap(URL(string: "about:blank"))))
    XCTAssertFalse(SchemePolicy.isLoadable(try XCTUnwrap(URL(string: "blob:https://a/1"))))
    XCTAssertFalse(SchemePolicy.isLoadable(try XCTUnwrap(URL(string: "data:text/html,x"))))
  }

  /// Catches a refusal that says nothing, or one that names no address, since the warning is the
  /// only thing the user sees.
  func testEveryRefusalNamesTheAddressAndSaysWhy() {
    let refusals: [(SchemeRefusal, String)] = [
      (.file, "local files"), (.javascript, "run script"), (.data, "made of data"),
      (.unsupported(scheme: "ftp"), "ftp:"), (.notAnAddress, "not a web address"),
    ]

    for (refusal, phrase) in refusals {
      let message = refusal.message(for: "the-address")

      XCTAssertTrue(message.contains("the-address"), message)
      XCTAssertTrue(message.contains(phrase), message)
    }
  }

  /// Catches an address a page chose, long enough that the status bar's own cut would remove the
  /// reason at the end of the sentence.
  func testAnAddressTooLongToShowIsCutBeforeItsReason() {
    let long = String(repeating: "a", count: 600)
    let message = SchemeRefusal.file.message(for: "file:///" + long)

    XCTAssertLessThan(message.count, 300)
    XCTAssertTrue(message.hasSuffix("does not open local files."), message)
  }

  /// Catches a download rule that follows the page rule and refuses the `blob:` and `data:` exports
  /// a dashboard makes, or one that lets `file:` or `javascript:` save.
  func testADownloadMayComeFromAnySchemeButFileAndJavascript() throws {
    let allowed = [
      "https://a/x", "http://a/x", "blob:https://a/1", "data:text/csv,a%2Cb", "ftp://a/x",
      "mailto:a@b.c", "BLOB:https://a/1",
    ]

    for address in allowed {
      XCTAssertEqual(
        SchemePolicy.decideDownload(try XCTUnwrap(URL(string: address))), .allow, address)
    }

    XCTAssertEqual(
      SchemePolicy.decideDownload(try XCTUnwrap(URL(string: "file:///etc/passwd"))),
      .refuse(.file))
    XCTAssertEqual(
      SchemePolicy.decideDownload(try XCTUnwrap(URL(string: "FILE:///etc/passwd"))),
      .refuse(.file))
    XCTAssertEqual(
      SchemePolicy.decideDownload(try XCTUnwrap(URL(string: "javascript:alert(1)"))),
      .refuse(.javascript))
  }
}
