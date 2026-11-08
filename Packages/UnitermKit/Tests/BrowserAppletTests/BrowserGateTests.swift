import AppletKit
import BrowserModel
import BrowserTestSupport
import StatusKit
import WebKit
import XCTest

@testable import BrowserApplet

/// The gates every load passes, whichever way it starts: the button methods, WebKit's own
/// gestures and menus, a redirect, and a server that asks for credentials.
@MainActor
final class BrowserGateTests: XCTestCase {
  private nonisolated static func server() -> FixtureServer.Handler {
    { request in
      switch (request.method, request.path) {
      case ("GET", "/form"):
        return Pages.page("Form", "<form method=post action=/result><input name=a value=1></form>")

      case ("GET", "/long-form"):
        let long = String(repeating: "a", count: 33 * 1024)

        return Pages.page(
          "LongForm", "<form method=post action='/result?q=\(long)'><input name=a value=1></form>")

      case ("POST", _) where request.path == "/result":
        return Pages.page("Posted")

      case ("GET", "/redirect-ftp"):
        return .redirect(to: "ftp://files.example.invalid/x", status: 302)

      case ("GET", "/redirect-file"):
        return .redirect(to: "file:///etc/hosts", status: 302)

      case ("GET", "/secret"):
        return FixtureServer.Response(
          status: 401,
          headers: [
            ("WWW-Authenticate", "Basic realm=\"fixture\""), ("Content-Type", "text/html"),
            ("Cache-Control", "no-store"),
          ], body: Data("<title>Denied</title>denied".utf8))

      default:
        return Pages.page("Other")
      }
    }
  }

  /// Catches a resubmit that gets past the applet's own buttons: the web view's own Reload and a
  /// swipe reach WebKit directly. The test calls the web view and not the tab, and the host would
  /// answer yes, so only the gate can stop the post. Each is refused with one warning and no
  /// question. A swipe cannot be told from a script, so it is refused too.
  func testWebKitsOwnReloadAndASwipeOntoAPostResultAreRefusedWithANotice() async throws {
    let harness = try await BrowserHarness.make(handler: Self.server())
    defer { harness.stop() }

    harness.host.recording.answer = true

    await harness.postResult()
    await harness.load("/other", expecting: "Other")

    harness.tab.webView.goBack()
    await harness.host.until("the swipe is refused") { harness.posts.count == 1 }

    XCTAssertTrue(harness.posts.first?.text.contains("send the form again") ?? false)

    await harness.load("/form", expecting: "Form")
    await harness.run("document.forms[0].submit()")
    await harness.host.until("the post result shows") {
      harness.applet.title == "Posted" && !harness.tab.isLoading
    }

    XCTAssertEqual(harness.count("POST", "/result"), 2)

    harness.host.recording.forgetSent()
    harness.tab.webView.reload()
    await harness.host.until("the web view's own reload is refused") { harness.posts.count == 1 }

    await harness.load("/barrier", expecting: "Other")

    XCTAssertEqual(harness.count("POST", "/result"), 2)
    XCTAssertTrue(harness.host.recording.confirmations.isEmpty)
  }

  /// Catches a post to an address too long to store being reloaded without a question. The flag that
  /// marks a post result must not depend on the address being storable.
  func testAPostToAnAddressTooLongToStoreIsStillNeverReloaded() async throws {
    let harness = try await BrowserHarness.make(handler: Self.server())
    defer { harness.stop() }

    await harness.postResult(from: "/long-form")

    harness.host.recording.answer = false
    harness.applet.reload()
    await harness.host.until("the question is asked") {
      harness.host.recording.confirmations.count == 1
    }

    await harness.load("/barrier", expecting: "Other")

    XCTAssertEqual(harness.count("POST", "/result"), 1)
  }

  /// Catches a same-document step on a post page, such as a fragment link, that gives a history
  /// entry whose reload sends the post again.
  func testAFragmentStepOnAPostPageDoesNotMakeItReloadable() async throws {
    let harness = try await BrowserHarness.make(handler: Self.server())
    defer { harness.stop() }

    await harness.postResult()
    await harness.run("location.hash = 'x'")
    await harness.host.until("the fragment shows") {
      harness.tab.webView.url?.fragment == "x"
    }

    harness.tab.webView.reload()
    await harness.load("/barrier", expecting: "Other")

    XCTAssertEqual(harness.count("POST", "/result"), 1)
    XCTAssertEqual(harness.tab.reload(), .moved)
  }

  /// Catches a redirect to a scheme the rule refuses that loads, or that fails with no word. A page
  /// is on screen, a typed address redirects to `ftp:` and to `file:`, and each time the page
  /// stays and one warning says so.
  func testARedirectToARefusedSchemeLeavesThePageAndWarnsOnce() async throws {
    let harness = try await BrowserHarness.make(handler: Self.server())
    defer { harness.stop() }

    await harness.load("/stay", expecting: "Other")
    let shown = harness.tab.webView.url

    for path in ["/redirect-ftp", "/redirect-file"] {
      harness.host.recording.forgetSent()
      harness.applet.submit(address: harness.server.url(path).absoluteString)
      await harness.host.until("the refusal is reported for \(path)") {
        !harness.posts.isEmpty
      }

      XCTAssertEqual(harness.posts.count, 1, path)
      XCTAssertEqual(harness.posts.first?.level, .warning, path)
      XCTAssertEqual(harness.tab.webView.url, shown, path)
    }
  }

  /// Catches a navigation delegate that answers an authentication challenge. The page shows the
  /// server's own 401, and no request the server sees carries credentials. WebKit asks the server
  /// twice, so the count is not part of the claim. A later trust or credential override would
  /// break this first.
  func testAServerThatAsksForCredentialsGetsNoneAndShowsItsOwnPage() async throws {
    let harness = try await BrowserHarness.make(handler: Self.server())
    defer { harness.stop() }

    harness.applet.submit(address: harness.server.url("/secret").absoluteString)
    await harness.host.until("the 401 page shows") {
      harness.applet.title == "Denied" && !harness.tab.isLoading
    }

    let seen = harness.server.requests.filter { $0.path == "/secret" }

    XCTAssertFalse(seen.isEmpty)
    XCTAssertTrue(seen.allSatisfy { $0.headers["authorization"] == nil }, "\(seen)")
    XCTAssertTrue(harness.posts.isEmpty, "\(harness.posts)")
  }
}
