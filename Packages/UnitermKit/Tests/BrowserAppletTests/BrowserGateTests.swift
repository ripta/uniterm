import AppletKit
import BrowserModel
import BrowserTestSupport
import StatusKit
import WebKit
import XCTest

@testable import BrowserApplet

/// The gates every load passes, whichever way it starts: the button methods, WebKit's own
/// gestures and menus, a redirect, a download, and a server that asks for credentials.
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

      case ("GET", "/zip"):
        return FixtureServer.Response(
          status: 200, headers: [("Content-Type", "application/zip")], body: Data("PK".utf8))

      case ("GET", "/attachment"):
        return FixtureServer.Response(
          status: 200,
          headers: [
            ("Content-Type", "text/plain"), ("Content-Disposition", "attachment; filename=a.txt"),
          ], body: Data("hello".utf8))

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

  private func postResult(in harness: BrowserHarness, from path: String = "/form") async {
    await harness.load(path, expecting: path == "/form" ? "Form" : "LongForm")
    await harness.run("document.forms[0].submit()")
    await harness.host.until("the post result shows") {
      harness.applet.title == "Posted" && !harness.tab.isLoading
    }
  }

  /// Catches a resubmit that gets past the button methods: the web view's own Reload, and a
  /// swipe, reach WebKit directly. The test calls the web view and not the tab, so only the
  /// navigation delegate can stop the post. One warning says why, and the server sees one post.
  func testWebKitsOwnReloadAndGoBackCannotResendAForm() async throws {
    let harness = try await BrowserHarness.make(handler: Self.server())
    defer { harness.stop() }

    await postResult(in: harness)
    await harness.load("/other", expecting: "Other")

    harness.tab.webView.goBack()
    await harness.host.until("the refusal is reported") { harness.posts.count == 1 }

    XCTAssertTrue(
      harness.posts.first?.text.contains("send the form again") ?? false, "\(harness.posts)")

    harness.host.recording.forgetSent()
    await harness.load("/form", expecting: "Form")
    await harness.run("document.forms[0].submit()")
    await harness.host.until("the post result shows") {
      harness.applet.title == "Posted" && !harness.tab.isLoading
    }

    XCTAssertEqual(harness.count("POST", "/result"), 2)

    harness.tab.webView.reload()
    await harness.host.until("the refusal is reported") { harness.posts.count == 1 }

    await harness.load("/barrier", expecting: "Other")

    XCTAssertEqual(harness.count("POST", "/result"), 2)
  }

  /// Catches a post to an address too long to store being reloadable. The flag that marks a post
  /// result must not depend on the address being storable.
  func testAPostToAnAddressTooLongToStoreIsStillNeverReloaded() async throws {
    let harness = try await BrowserHarness.make(handler: Self.server())
    defer { harness.stop() }

    await postResult(in: harness, from: "/long-form")

    XCTAssertEqual(harness.count("POST", "/result"), 1)
    XCTAssertEqual(harness.tab.reload(), .refusedResubmit)
  }

  /// Catches a same-document step on a post page, such as a fragment link, that gives a history
  /// entry whose reload sends the post again.
  func testAFragmentStepOnAPostPageDoesNotMakeItReloadable() async throws {
    let harness = try await BrowserHarness.make(handler: Self.server())
    defer { harness.stop() }

    await postResult(in: harness)
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

  /// Catches a response the browser cannot show, or one the server marks as an attachment, that
  /// fails with no word. WebKit reports both as an interrupted load. The user hears one warning
  /// that downloads are not available.
  func testAResponseThatWouldDownloadWarnsOnce() async throws {
    let harness = try await BrowserHarness.make(handler: Self.server())
    defer { harness.stop() }

    for path in ["/zip", "/attachment"] {
      harness.host.recording.forgetSent()
      harness.applet.submit(address: harness.server.url(path).absoluteString)
      await harness.host.until("the warning arrives for \(path)") { !harness.posts.isEmpty }

      XCTAssertEqual(harness.posts.count, 1, path)
      XCTAssertTrue(
        harness.posts.first?.text.contains("Downloads are not available") ?? false,
        "\(path): \(harness.posts)")
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
