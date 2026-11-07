import AppletKit
import BrowserTestSupport
import WebKit
import XCTest

@testable import BrowserApplet

/// Cancelling a download that has received no byte. Measured against a real web view: WebKit's
/// network process treats a cancel that beats the first byte as an invalid message, and restarts.
/// Every other pane then loses its session state and any load in flight. The test crash folder
/// shows an `EXC_GUARD` report from `NetworkProcessProxy::didReceiveInvalidMessage` each time. A
/// cancel that comes after a byte does not. A non-persistent store keeps its cookies only in the
/// network process, so a session cookie that survives is the proof it stayed up.
@MainActor
final class BrowserDownloadCancelTests: XCTestCase {
  private func handler(
    _ hold: FixtureServer.Hold, body: String
  ) -> FixtureServer.Handler {
    { request in
      switch request.path {
      case "/cookie":
        return FixtureServer.Response(
          status: 200,
          headers: [
            ("Content-Type", "text/html"), ("Set-Cookie", "sid=1; Path=/"),
            ("Cache-Control", "no-store"),
          ], body: Data("<title>Cookie</title>".utf8))

      case "/echo":
        return Pages.page("Echo")

      default:
        return FixtureServer.Response(
          status: 200,
          headers: [
            ("Content-Type", "application/octet-stream"),
            ("Content-Disposition", "attachment; filename=\"held.bin\""),
          ], body: Data(body.utf8), hold: hold, tail: Data("llo".utf8))
      }
    }
  }

  private func make(
    _ hold: FixtureServer.Hold, body: String, grace: Duration = .seconds(30)
  ) async throws -> BrowserHarness {
    try await BrowserHarness.make(
      services: .testing(cancelGrace: grace), dataStore: .nonPersistent(),
      handler: handler(hold, body: body))
  }

  private func startHeld(_ harness: BrowserHarness) async {
    harness.applet.submit(address: harness.server.url("/held").absoluteString)
    await harness.host.until("the download has a file") {
      harness.applet.downloads.active.first?.temporary != nil
    }
  }

  private func cookieSeen(_ harness: BrowserHarness) async -> String? {
    harness.applet.submit(address: harness.server.url("/echo").absoluteString)
    await harness.host.until("the echo page shows") { harness.applet.title == "Echo" }

    return harness.server.requests.last { $0.path == "/echo" }?.headers["cookie"]
  }

  private func files(in harness: BrowserHarness) -> [String] {
    guard let directory = harness.downloadsDirectory else { return [] }

    return ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
  }

  /// Pins the symptom of a cancel that restarts the network process. The user cancels a download
  /// right after its destination is set, while its first bytes are still on the way. A session
  /// cookie that another tab sends afterwards is still there once the rest of the body has arrived
  /// for the cancelled download. The file is removed and nothing is announced. A scratch run
  /// measured the cookie gone after a cancel before data, in a single cycle and in twelve, and kept
  /// after a cancel past data or an abort. This committed form did not reproduce the loss on the
  /// unfixed code, so the structural test below is the one that failed first.
  func testACancelRightAfterTheDestinationKeepsTheNetworkProcessUp() async throws {
    let hold = FixtureServer.Hold()
    let harness = try await make(hold, body: "he")
    defer { harness.stop() }

    await harness.load("/cookie", expecting: "Cookie")

    await startHeld(harness)

    harness.applet.downloads.cancelAll()

    XCTAssertFalse(harness.applet.isRunningSomething)

    for _ in 0..<1500 { await Task.yield() }

    hold.release()

    await harness.eventually("the cancel has gone to WebKit") {
      harness.applet.downloads.deferredCancelCount == 0
    }
    await harness.eventually("the partial file is gone") { files(in: harness).isEmpty }

    for _ in 0..<1500 { await Task.yield() }

    harness.applet.openTab()

    let seen = await cookieSeen(harness)

    XCTAssertEqual(seen, "sid=1", "the cancel restarted the network process")
    XCTAssertEqual(harness.posts.map(\.text), [])
  }

  /// Catches a cancel that goes to WebKit with no byte yet. A response that holds back its body
  /// leaves the cancel waiting, and the pane stops running at once. The first byte lets it go, the
  /// file is removed, and nothing is announced.
  func testACancelWithNoByteYetWaitsForOne() async throws {
    let hold = FixtureServer.Hold()
    let harness = try await make(hold, body: "")
    defer { harness.stop() }

    await startHeld(harness)

    harness.applet.downloads.cancelAll()

    XCTAssertEqual(harness.applet.downloads.deferredCancelCount, 1)
    XCTAssertFalse(harness.applet.isRunningSomething)

    hold.release()

    await harness.eventually("the cancel goes to WebKit with the first byte") {
      harness.applet.downloads.deferredCancelCount == 0
    }
    await harness.eventually("the partial file is gone") { files(in: harness).isEmpty }

    XCTAssertEqual(harness.posts.map(\.text), [])
  }

  /// Catches a cancel that beats the destination answer. WebKit still gets a destination, since
  /// refusing one cancels the download before its first byte. The cancel then waits for a byte like
  /// any other, and the network process stays up.
  func testACancelBeforeTheDestinationIsAnsweredStaysQuiet() async throws {
    let hold = FixtureServer.Hold()
    let harness = try await make(hold, body: "he")
    defer { harness.stop() }

    await harness.load("/cookie", expecting: "Cookie")

    harness.applet.submit(address: harness.server.url("/held").absoluteString)
    await harness.host.until("the download is adopted") {
      !harness.applet.downloads.active.isEmpty
    }

    harness.applet.downloads.cancelAll()

    await harness.eventually("the cancel goes through") {
      harness.applet.downloads.deferredCancelCount == 0
    }
    await harness.eventually("no file is left") { files(in: harness).isEmpty }

    for _ in 0..<1500 { await Task.yield() }

    let seen = await cookieSeen(harness)

    XCTAssertEqual(seen, "sid=1")

    hold.release()
  }

  /// Catches a cancel that waits when a byte is already there. It goes to WebKit at once.
  func testACancelAfterABytePassesStraightToWebKit() async throws {
    let hold = FixtureServer.Hold()
    let harness = try await make(hold, body: "he")
    defer { harness.stop() }

    await startHeld(harness)
    await harness.eventually("a byte arrives") {
      harness.applet.downloads.active.first?.hasData ?? true
    }

    harness.applet.downloads.cancelAll()

    XCTAssertEqual(harness.applet.downloads.deferredCancelCount, 0)

    hold.release()
  }

  /// Catches a deferred cancel that never ends when no byte comes. After the grace it goes to
  /// WebKit anyway, and the file is removed. The grace is injected, so the test waits for a
  /// moment and not for half a minute.
  func testADeferredCancelEndsAfterTheGraceWhenNoByteComes() async throws {
    let hold = FixtureServer.Hold()
    let harness = try await make(hold, body: "", grace: .milliseconds(100))
    defer { harness.stop() }

    await startHeld(harness)

    harness.applet.downloads.cancelAll()

    XCTAssertEqual(harness.applet.downloads.deferredCancelCount, 1)

    await harness.eventually("the grace ends the wait") {
      harness.applet.downloads.deferredCancelCount == 0
    }
    await harness.eventually("the partial file is gone") { files(in: harness).isEmpty }

    XCTAssertEqual(harness.posts.map(\.text), [])

    hold.release()
  }

  /// Catches a deferred download that fails before its cancel goes out and leaves a stale entry,
  /// announces a failure the user cancelled, or keeps its file.
  func testADeferredDownloadThatFailsFirstCleansUpQuietly() async throws {
    let hold = FixtureServer.Hold()
    let harness = try await make(hold, body: "")
    defer { harness.stop() }

    await startHeld(harness)

    harness.applet.downloads.cancelAll()
    hold.abort()

    await harness.eventually("the failed download is forgotten") {
      harness.applet.downloads.deferredCancelCount == 0
    }
    await harness.eventually("the partial file is gone") { files(in: harness).isEmpty }

    XCTAssertEqual(harness.posts.map(\.text), [])
    XCTAssertFalse(harness.applet.isRunningSomething)
  }
}
