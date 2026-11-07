import BrowserTestSupport
import WebKit
import XCTest

@testable import BrowserApplet

/// Camera and microphone requests fail at once with `NotAllowedError`. Without the script, a real
/// request returns a promise that never settles, so each call is raced against a short timer.
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

  /// Catches a request that never settles. `mediaDevices` exists on the fixture's origin, since
  /// 127.0.0.1 is a secure context. Each form of the main page gets the error.
  func testEachRequestInThePageFailsAtOnceWithNotAllowedError() async throws {
    let harness = try await BrowserHarness.make(hosting: .window, handler: Self.handler)
    defer { harness.stop() }

    await harness.load("/page", expecting: "Page")

    let present = try await harness.tab.webView.evaluateJavaScript(
      "typeof navigator.mediaDevices.getUserMedia + ' ' + typeof navigator.mediaDevices.getDisplayMedia"
    )

    XCTAssertEqual(present as? String, "function function", "the origin has no mediaDevices")

    let listing = try await harness.tab.webView.evaluateJavaScript(
      "String(navigator.mediaDevices.enumerateDevices).includes('[native code]')")

    XCTAssertEqual(listing as? Bool, true, "listing devices was replaced")

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

  private func plainView(scripts: [String]) -> WKWebView {
    let controller = WKUserContentController()

    for source in scripts {
      controller.addUserScript(
        WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    }

    MediaCaptureScript.install(in: controller)

    let configuration = WKWebViewConfiguration()

    configuration.userContentController = controller

    return WKWebView(frame: .zero, configuration: configuration)
  }

  /// Catches legacy callback forms that stay pending. WebKit here exposes neither
  /// `navigator.getUserMedia` nor `webkitGetUserMedia`, so a stub script runs first and defines
  /// them. That proves the replacement logic and not the real WebKit objects.
  func testTheLegacyCallbackFormsCallTheErrorCallback() async throws {
    let stub = """
      navigator.getUserMedia = function () {};
      navigator.webkitGetUserMedia = function () {};
      """
    let view = plainView(scripts: [stub])

    view.loadHTMLString("<title>x</title>", baseURL: URL(string: "https://secure.example/"))
    try await settle(view)

    for name in ["getUserMedia", "webkitGetUserMedia"] {
      let call = """
        new Promise(function (resolve, reject) {
          navigator.\(name)({ audio: true }, function () { resolve('stream'); },
            function (error) { reject(error); });
        })
        """
      let result = try await outcome(of: call, in: view)

      XCTAssertEqual(result, "NotAllowedError", name)
    }
  }

  /// Catches a script that defines `mediaDevices` where WebKit does not. A page on an insecure
  /// origin has none, and keeps none.
  func testAnInsecurePageStaysWithoutMediaDevices() async throws {
    let view = plainView(scripts: [])

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
