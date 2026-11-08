import AppletKit
import BrowserModel
import BrowserTestSupport
import XCTest

@testable import BrowserApplet

/// What `describe()` costs while a page misbehaves. The window calls it on every change an applet
/// reports, and a page chooses how often its title changes.
@MainActor
final class BrowserDescribeCostTests: XCTestCase {
  private nonisolated static func handler() -> FixtureServer.Handler {
    { request in Pages.page(String(request.path.dropFirst()).uppercased()) }
  }

  /// Catches a description that reads WebKit's history record again for every title change. A page
  /// sets its title 40 times, and the test describes the pane at every change the applet reports.
  /// No read happens, since a title is not history.
  func testABurstOfTitleChangesReadsNoHistory() async throws {
    let harness = try await BrowserHarness.make(handler: Self.handler())
    defer { harness.stop() }

    await harness.load("/a", expecting: "A")
    await harness.load("/b", expecting: "B")

    let web = try XCTUnwrap(harness.tab.webView as? BrowserWebView)
    let applet = harness.applet

    _ = applet.describe()

    let before = web.interactionStateReads

    for index in 0..<40 {
      await harness.run("document.title = 't\(index)'")
      await harness.host.until("title \(index) shows") {
        _ = applet.describe()

        return applet.title == "t\(index)"
      }
    }

    XCTAssertEqual(web.interactionStateReads, before)
  }

  /// Catches a cache that never refreshes. A new page is history, so the next description reads it
  /// and carries the new record.
  func testANewPageIsReadOnceAndThenCached() async throws {
    let harness = try await BrowserHarness.make(handler: Self.handler())
    defer { harness.stop() }

    await harness.load("/a", expecting: "A")

    let web = try XCTUnwrap(harness.tab.webView as? BrowserWebView)
    let first = harness.applet.describe()
    let afterFirst = web.interactionStateReads

    _ = harness.applet.describe()

    XCTAssertEqual(web.interactionStateReads, afterFirst)

    await harness.load("/b", expecting: "B")

    let second = harness.applet.describe()

    XCTAssertGreaterThan(web.interactionStateReads, afterFirst)
    XCTAssertNotEqual(first.undoState, second.undoState)
  }
}
