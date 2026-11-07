import AppKit
import AppletKit
import BrowserModel
import BrowserTestSupport
import WebKit
import XCTest

@testable import BrowserApplet

/// What a pane's detach and reattach do to a browser tab's media. Nothing in the host sends these
/// events, so each test calls them. The page plays a generated silent tone, so no test makes
/// sound or reads a file.
@MainActor
final class BrowserDetachTests: XCTestCase {
  private nonisolated static let page = """
    <title>Media</title><audio id=tone loop></audio>
    <script>
    function wav() {
      var rate = 8000, samples = rate, buffer = new ArrayBuffer(44 + samples), v = new DataView(buffer);
      function text(offset, s) { for (var i = 0; i < s.length; i++) v.setUint8(offset + i, s.charCodeAt(i)); }
      text(0, 'RIFF'); v.setUint32(4, 36 + samples, true); text(8, 'WAVEfmt ');
      v.setUint32(16, 16, true); v.setUint16(20, 1, true); v.setUint16(22, 1, true);
      v.setUint32(24, rate, true); v.setUint32(28, rate, true); v.setUint16(32, 1, true);
      v.setUint16(34, 8, true); text(36, 'data'); v.setUint32(40, samples, true);
      for (var i = 0; i < samples; i++) v.setUint8(44 + i, 128);
      return new Blob([buffer], {type: 'audio/wav'});
    }
    document.getElementById('tone').src = URL.createObjectURL(wav());
    </script>
    """

  private func state(_ harness: BrowserHarness) async -> WKMediaPlaybackState {
    await harness.tab.webView.requestMediaPlaybackState()
  }

  /// Catches a detached pane that keeps playing sound, and a reattach that starts it again. Detach
  /// suspends every tab's media, which pauses it and blocks play. Reattach lifts the block and does
  /// not resume what was paused. Under `swift test` the page's `play()` stays pending, since no
  /// audio output starts it, so the state never reaches playing. The test proves the suspend and
  /// the lift against the media element's reported state. That playing audio actually pauses is
  /// left to the user.
  func testDetachSuspendsMediaAndReattachDoesNotResumeIt() async throws {
    let harness = try await BrowserHarness.make { _ in Pages.page("Media", "") }
    defer { harness.stop() }

    harness.tab.webView.loadHTMLString(Self.page, baseURL: harness.server.url("/"))
    await harness.host.until("the page shows") { harness.applet.title == "Media" }

    await harness.run("document.getElementById('tone').play().catch(function () {}); void 0")

    harness.applet.detach()

    await harness.eventuallyAsync("the media is suspended") {
      await self.state(harness) == .suspended
    }

    XCTAssertTrue(harness.tab.isMediaSuspended)

    harness.applet.reattach()

    await harness.eventuallyAsync("the suspension lifts") {
      await self.state(harness) != .suspended
    }

    let afterReattach = await state(harness)

    let paused = await harness.run("document.getElementById('tone').paused") as? Bool

    XCTAssertNotEqual(afterReattach, .playing, "reattach resumed the media")
    XCTAssertEqual(paused, true, "reattach resumed the media")
    XCTAssertFalse(harness.tab.isMediaSuspended)
  }

  /// Catches a tab built, or given a web view, while the pane is detached that plays freely. Its
  /// suspension applies when the web view comes to be.
  func testATabThatGetsItsWebViewWhileDetachedStartsSuspended() async throws {
    let harness = try await BrowserHarness.make()
    defer { harness.stop() }

    let tab = BrowserTab(
      id: .make(), record: BrowserDescription.Tab(), dataStore: .nonPersistent(), hsts: HSTSStore())

    tab.setMediaSuspended(true)

    XCTAssertFalse(tab.isMaterialized)
    XCTAssertTrue(tab.isMediaSuspended)

    _ = tab.webView

    XCTAssertTrue(tab.isMaterialized)
    XCTAssertTrue(tab.isMediaSuspended)

    tab.close()
  }
}
