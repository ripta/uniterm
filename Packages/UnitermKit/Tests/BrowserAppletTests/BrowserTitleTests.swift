import AppKit
import AppletKit
import BrowserModel
import BrowserTestSupport
import XCTest

@testable import BrowserApplet

/// A page chooses its title, and every place the applet repeats it is read by the user: the pane
/// title the host puts in its own questions and closed-pane list, the tab bar, a notice from a
/// background tab, and the close question.
@MainActor
final class BrowserTitleTests: XCTestCase {
  private nonisolated static let rawTitle =
    "Pay &#x202E;gnp.exe\u{0A}  here " + String(repeating: "x", count: 10_000)

  private nonisolated static let pages: FixtureServer.Handler = { request in
    switch request.path {
    case "/odd":
      return Pages.page(rawTitle, "<input id=a value=draft>")

    default:
      return Pages.page("Two")
    }
  }

  private func assertClean(
    _ text: String, _ what: String, limit: Int = 200, file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertFalse(
      text.unicodeScalars.contains { $0.value == 0x202E }, "\(what): \(text)", file: file,
      line: line)
    XCTAssertFalse(text.contains("\n"), "\(what) holds a line break", file: file, line: line)
    XCTAssertLessThanOrEqual(
      text.count, limit, "\(what) is \(text.count) characters", file: file, line: line)
  }

  /// Catches a page title that reaches the user raw. A title with a bidi override, a line break,
  /// and 10,000 characters is read back from the pane title, the published tab list, a notice from
  /// a background tab, the close question, and the reopened tab's name. Each is clean and bounded.
  /// It cannot prove how the tab bar draws a clean title.
  func testAPageTitleReachesEveryPlaceCleanAndBounded() async throws {
    let harness = try await BrowserHarness.make(hosting: .focusedWindow, handler: Self.pages)
    defer { harness.stop() }

    harness.applet.submit(address: harness.server.url("/odd").absoluteString)
    await harness.host.until("the odd page loads") {
      harness.tab.pageTitle != nil && !harness.tab.isLoading
    }

    await harness.run(
      "var e = document.getElementById('a'); e.focus(); e.select();")
    (harness.tab.webView as? any NSTextInputClient)?.insertText(
      "changed", replacementRange: NSRange(location: NSNotFound, length: 0))
    await harness.host.until("the tab is marked") { harness.tab.hasUnsentInput }

    assertClean(harness.applet.title, "the pane title")
    assertClean(harness.applet.publishedTabs.first.title, "the tab bar title")

    harness.applet.openTab()
    await harness.load("/two", expecting: "Two")

    let background = harness.applet.tabs[0]

    _ = try? await background.webView.evaluateJavaScript(
      "location.href = 'ftp://example.invalid/x'")
    await harness.host.until("the background tab's notice arrives") { harness.posts.count == 1 }
    assertClean(harness.posts[0].text, "the background notice", limit: 400)

    harness.host.recording.answer = false

    let declined = await harness.applet.closeTab(at: 0)

    XCTAssertEqual(declined, .declined)

    let detail = try XCTUnwrap(harness.host.recording.confirmations.last?.detail)

    assertClean(detail, "the close question", limit: 400)

    harness.host.recording.answer = true

    let closed = await harness.applet.closeTab(at: 0)

    XCTAssertEqual(closed, .closed)

    let stamp = try XCTUnwrap(harness.applet.closedTabStamps.first)

    guard case .reopened(let title) = harness.applet.reopenTab(stamp: stamp) else {
      return XCTFail("the closed tab did not reopen")
    }

    assertClean(title, "the reopened tab's name")
  }
}
