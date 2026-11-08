import AppKit
import XCTest

@testable import BrowserApplet

/// The warning icon against a real web view. The fixture speaks plain HTTP, and WebKit rejects a
/// self-signed HTTPS fixture. A page loaded from a string with an `https` base address still
/// commits as an `https` page, and WebKit reports it as fully secure, so it stands in for a secure
/// page. WebKit blocks or upgrades mixed content in that page before the flag can change. No test
/// here proves the flag flipping after commit. The observer that follows it is covered only by
/// reading the code and by the manual check of an HTTPS page that loads insecure content.
@MainActor
final class BrowserSecurityTests: XCTestCase {
  private static func loadSecurePage(_ harness: BrowserHarness) async {
    harness.tab.webView.loadHTMLString(
      "<title>Secure</title><body>hi", baseURL: URL(string: "https://example.com/"))

    await harness.host.until("the secure page shows") { [applet = harness.applet] in
      applet.title == "Secure" && !applet.tab.isLoading
    }
  }

  /// Catches a flag that never reaches the icon, and an icon that VoiceOver and UI tests cannot
  /// find. A blank tab must start without a warning.
  func testAnHTTPPageShowsTheWarningAndABlankTabDoesNot() async throws {
    let harness = try await BrowserHarness.make { _ in Pages.page("Plain") }
    defer { harness.stop() }

    let icon = harness.applet.content.securityIcon

    XCTAssertTrue(icon.isHidden)
    XCTAssertEqual(icon.accessibilityIdentifier(), "browser-security")
    XCTAssertEqual(icon.accessibilityLabel(), "Not secure")

    await harness.load("/", expecting: "Plain")

    XCTAssertTrue(harness.tab.showsSecurityWarning)
    XCTAssertFalse(icon.isHidden)
  }

  /// Catches a warning on a page WebKit reports as fully secure. It cannot show that a page
  /// fetched over real TLS gets the same report.
  func testAFullySecurePageShowsNoWarning() async throws {
    let harness = try await BrowserHarness.make()
    defer { harness.stop() }

    await Self.loadSecurePage(harness)

    XCTAssertTrue(harness.tab.webView.hasOnlySecureContent)
    XCTAssertFalse(harness.tab.showsSecurityWarning)
    XCTAssertTrue(harness.applet.content.securityIcon.isHidden)
  }

  /// Catches a warning that waits for the commit. WebKit moves the address to the new page before
  /// it commits, and a stalled `http` load from a secure page must warn already, not show a
  /// secure-looking address.
  func testALoadStalledOnAnHTTPPageFromASecurePageWarnsAtOnce() async throws {
    let gate = DispatchSemaphore(value: 0)
    let harness = try await BrowserHarness.make { request in
      if request.path == "/slow" { _ = gate.wait(timeout: .now() + 20) }
      return Pages.page("Slow")
    }
    defer {
      gate.signal()
      harness.stop()
    }

    await Self.loadSecurePage(harness)

    // A change of address or flag is not a change the applet reports to its host, so the wait
    // listens to the web view directly. The tab's own observers were registered first and run first.
    let changes = AsyncStream.makeStream(of: Void.self)
    let observers = [
      harness.tab.webView.observe(\.url) { _, _ in changes.continuation.yield() },
      harness.tab.webView.observe(\.hasOnlySecureContent) { _, _ in changes.continuation.yield() },
    ]

    let timer = Task { @MainActor in
      try? await Task.sleep(for: .seconds(30))
      changes.continuation.finish()
    }

    defer {
      timer.cancel()
      for observer in observers { observer.invalidate() }
    }

    harness.applet.submit(address: harness.server.url("/slow").absoluteString)

    var warned = false

    for await _ in changes.stream {
      if harness.tab.currentURL?.path == "/slow", harness.tab.isLoading {
        warned = harness.tab.showsSecurityWarning
        break
      }
    }

    XCTAssertTrue(warned, "the stalled address shows with a warning")
    XCTAssertFalse(harness.applet.content.securityIcon.isHidden)
  }

  /// Catches a `blob:` page made by an insecure page that shows no warning.
  func testABlobPageMadeByAnHTTPPageWarns() async throws {
    let harness = try await BrowserHarness.make { _ in
      Pages.page(
        "Source",
        "<script>location = URL.createObjectURL(new Blob(['<title>Blob</title>x'], {type: 'text/html'}))</script>"
      )
    }
    defer { harness.stop() }

    harness.applet.submit(address: harness.server.url("/").absoluteString)
    await harness.host.until("the blob page shows") {
      [tab = harness.tab, applet = harness.applet] in
      tab.currentURL?.scheme == "blob" && applet.title == "Blob" && !tab.isLoading
    }

    XCTAssertTrue(harness.tab.showsSecurityWarning)
  }

  /// Catches a warning that sticks after the user leaves an insecure page. The state must follow
  /// the page, and a navigation to a blank page loses the icon.
  func testNavigatingAwayFromAnInsecurePageClearsTheWarning() async throws {
    let harness = try await BrowserHarness.make { _ in Pages.page("Plain") }
    defer { harness.stop() }

    await harness.load("/", expecting: "Plain")

    let icon = harness.applet.content.securityIcon

    XCTAssertFalse(icon.isHidden)

    harness.applet.submit(address: "about:blank")
    await harness.host.until("the warning clears") { [tab = harness.tab] in
      tab.currentURL?.absoluteString == "about:blank" && !tab.showsSecurityWarning
    }

    XCTAssertTrue(icon.isHidden)
  }

  /// Pins the view's half of the wiring, and that a hidden icon gives its room to the address bar.
  func testTheIconTakesRoomOnlyWhileItWarns() {
    let view = BrowserView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))

    view.layoutSubtreeIfNeeded()
    let hiddenWidth = view.addressField.frame.width

    view.show(securityWarning: true)
    view.layoutSubtreeIfNeeded()

    XCTAssertFalse(view.securityIcon.isHidden)
    XCTAssertLessThan(view.addressField.frame.width, hiddenWidth)

    view.show(securityWarning: false)
    view.layoutSubtreeIfNeeded()

    XCTAssertTrue(view.securityIcon.isHidden)
    XCTAssertEqual(view.addressField.frame.width, hiddenWidth)
  }
}
