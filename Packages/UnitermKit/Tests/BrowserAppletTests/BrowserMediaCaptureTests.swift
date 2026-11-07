import BrowserTestSupport
import WebKit
import XCTest

@testable import BrowserApplet

/// Camera and microphone requests fail at once with `NotAllowedError`, through a stand-in for
/// `navigator.mediaDevices`. The app has no usage strings, so WebKit hides the native API there.
/// This test runner has strings of its own, so it has the native API, and the stand-in must replace
/// it. Each call is raced against a short timer, since a native request here never settles. These
/// tests cannot show the app's own missing API. The app's plist is pinned in `InfoPlistDriftTests`.
@MainActor
final class BrowserMediaCaptureTests: XCTestCase {
  private nonisolated static let handler: FixtureServer.Handler = { request in
    switch request.path {
    case "/frame":
      return Pages.page("Frame")

    case "/page":
      return Pages.page("Page", "<iframe id=sub src=/frame></iframe>")

    default:
      return Pages.page(String(request.path.dropFirst()).uppercased())
    }
  }

  /// Calls `call` in `view` and returns the name of the error it rejects with, `resolved` when it
  /// succeeds, or `timeout` when it stays pending past the bound.
  private func outcome(
    of call: String, in view: WKWebView, bound: Int = 2000
  ) async throws -> String {
    let script = """
      var pending = new Promise(function (resolve) { setTimeout(function () { resolve('timeout'); }, \(bound)); });
      var call = (async function () {
        try { await (\(call)); return 'resolved'; } catch (error) { return error.name; }
      })();
      return await Promise.race([call, pending]);
      """

    let value = try await view.callAsyncJavaScript(
      script, arguments: [:], in: nil, contentWorld: .page)

    return value as? String ?? "none"
  }

  private let forms = [
    "navigator.mediaDevices.getUserMedia({ audio: true })",
    "navigator.mediaDevices.getUserMedia({ video: true })",
    "navigator.mediaDevices.getDisplayMedia({ video: true })",
  ]

  /// Catches a page left with the native API, or a stand-in missing what a site calls. 127.0.0.1 is
  /// a secure context, so the page gets the stand-in. Each request gets the error, listing devices
  /// finds none, and a site can still listen for device changes.
  func testEachRequestInThePageFailsAtOnceWithNotAllowedError() async throws {
    let harness = try await BrowserHarness.make(hosting: .window, handler: Self.handler)
    defer { harness.stop() }

    await harness.load("/page", expecting: "Page")

    let native = try await harness.tab.webView.evaluateJavaScript(
      "navigator.mediaDevices instanceof MediaDevices")

    XCTAssertEqual(native as? Bool, false, "the page still has the native API")

    let listed = try await harness.tab.webView.callAsyncJavaScript(
      """
      navigator.mediaDevices.addEventListener('devicechange', function () {});
      var found = await navigator.mediaDevices.enumerateDevices();
      return found.length + ' ' + typeof navigator.mediaDevices.getSupportedConstraints();
      """, arguments: [:], in: nil, contentWorld: .page)

    XCTAssertEqual(listed as? String, "0 object")

    for call in forms {
      let result = try await outcome(of: call, in: harness.tab.webView)

      XCTAssertEqual(result, "NotAllowedError", call)
    }
  }

  /// Catches a script that skips subframes. A frame has its own `navigator`.
  func testARequestFromASubframeFailsToo() async throws {
    let harness = try await BrowserHarness.make(hosting: .window, handler: Self.handler)
    defer { harness.stop() }

    await harness.load("/page", expecting: "Page")

    for form in forms {
      let call = form.replacingOccurrences(
        of: "navigator", with: "document.getElementById('sub').contentWindow.navigator")
      let result = try await outcome(of: call, in: harness.tab.webView)

      XCTAssertEqual(result, "NotAllowedError", call)
    }
  }

  /// Catches a pop-up that is built from WebKit's configuration without the script.
  func testARequestFromAPopUpFailsToo() async throws {
    let harness = try await BrowserHarness.make(hosting: .window, handler: Self.handler)
    defer { harness.stop() }

    await harness.load("/page", expecting: "Page")
    await harness.run("window.open('/popup')")
    await harness.host.until("the pop-up opens") {
      harness.applet.tabCount == 2 && harness.applet.title == "POPUP"
    }

    XCTAssertTrue(harness.tab.isPopup)

    for call in forms {
      let result = try await outcome(of: call, in: harness.tab.webView)

      XCTAssertEqual(result, "NotAllowedError", call)
    }
  }

  private func plainView() -> WKWebView {
    let controller = WKUserContentController()

    MediaCaptureScript.install(in: controller)

    let configuration = WKWebViewConfiguration()

    configuration.userContentController = controller

    return WKWebView(frame: .zero, configuration: configuration)
  }

  /// Catches a stand-in on a page where no browser has the API. A page on an insecure origin has
  /// none, and keeps none.
  func testAnInsecurePageStaysWithoutMediaDevices() async throws {
    let view = plainView()

    view.loadHTMLString("<title>x</title>", baseURL: URL(string: "http://insecure.example/"))
    try await settle(view)

    let result = try await view.evaluateJavaScript(
      "window.isSecureContext + ' ' + typeof navigator.mediaDevices")

    XCTAssertEqual(result as? String, "false undefined")
  }

  private func settle(_ view: WKWebView) async throws {
    for _ in 0..<500 {
      if !view.isLoading, view.url != nil { return }

      try await Task.sleep(for: .milliseconds(10))
    }
  }
}
