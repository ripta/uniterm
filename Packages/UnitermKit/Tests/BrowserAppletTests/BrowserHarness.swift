import AppKit
import AppletKit
import AppletTestSupport
import BrowserTestSupport
import StatusKit
import WebKit
import XCTest

@testable import BrowserApplet

/// Stands in for the pane. It records what the applet tells its pane, and it wakes a waiting test at
/// every call, so a test waits for the applet's own report and never polls or sleeps.
@MainActor
final class EventHost: AppletHost {
  let recording = RecordingHost()
  private let events = AsyncStream.makeStream(of: Void.self)

  func applet(
    _ applet: any Applet, send delivery: StatusDelivery, level: StatusLevel, text: String,
    presenting record: StatusRecordID?
  ) -> StatusRecordID? {
    defer { events.continuation.yield() }
    return recording.applet(
      applet, send: delivery, level: level, text: text, presenting: record)
  }

  func appletDidExit(_ applet: any Applet) { recording.appletDidExit(applet) }

  func appletDidChange(_ applet: any Applet) {
    recording.appletDidChange(applet)
    events.continuation.yield()
  }

  func appletTabsDidChange(_ applet: any Applet) {
    recording.appletTabsDidChange(applet)
    events.continuation.yield()
  }

  func applet(_ applet: any Applet, confirm request: AppletConfirmation) async -> Bool {
    Task { @MainActor [events] in events.continuation.yield() }

    return await recording.applet(applet, confirm: request)
  }

  func issueCloseStamp() -> UInt64 { recording.issueCloseStamp() }

  /// Returns once `condition` holds. It checks first, then waits for the applet's next report. A
  /// condition that never holds ends the test with a failure after `seconds`, so a hung page fails
  /// instead of hanging the run. The timer runs only on that path.
  func until(
    _ message: String, seconds: Int = 30, file: StaticString = #filePath, line: UInt = #line,
    _ condition: @MainActor @escaping () -> Bool
  ) async {
    if condition() { return }

    var timedOut = false

    let timer = Task { @MainActor in
      try? await Task.sleep(for: .seconds(seconds))

      guard !Task.isCancelled else { return }

      timedOut = true
      events.continuation.yield()
    }

    defer { timer.cancel() }

    for await _ in events.stream {
      if condition() { return }

      if timedOut {
        XCTFail("timed out waiting until \(message)", file: file, line: line)
        return
      }
    }
  }
}

/// One applet against one local server, with a private website data store so no test shares
/// cookies or touches the user's.
@MainActor
final class BrowserHarness {
  let server: FixtureServer
  let host = EventHost()
  let applet: BrowserApplet

  var tab: BrowserTab { applet.tab }
  var posts: [(level: StatusLevel, text: String)] { host.recording.posts }

  static func make(
    handler: @escaping FixtureServer.Handler = { _ in .page(titled: "ok") }
  ) async throws -> BrowserHarness {
    let server = try await FixtureServer.start(handler: handler)
    let applet = BrowserApplet(dataStore: .nonPersistent())

    return BrowserHarness(server: server, applet: applet)
  }

  init(server: FixtureServer, applet: BrowserApplet) {
    self.server = server
    self.applet = applet

    applet.host = host
    applet.start(origin: .user)
  }

  func stop() {
    applet.close()
    server.stop()
  }

  /// The pages the server has served for `path`, by method.
  func count(_ method: String, _ path: String) -> Int {
    server.requests.filter { $0.method == method && $0.path == path }.count
  }

  func load(_ path: String, expecting title: String) async {
    applet.submit(address: server.url(path).absoluteString)
    await host.until("the page titled \(title) shows") { [applet] in
      applet.title == title && !applet.tab.isLoading
    }
  }

  @discardableResult
  func run(_ script: String) async -> Any? {
    try? await tab.webView.evaluateJavaScript(script)
  }
}

/// Pages the fixture server serves. Each sends no-store, so a move through history asks the server
/// again and a test counts requests exactly.
enum Pages {
  nonisolated static let noStore = [
    ("Cache-Control", "no-store"), ("Content-Type", "text/html"),
  ]

  nonisolated static func page(_ title: String, _ body: String = "") -> FixtureServer.Response {
    FixtureServer.Response(
      status: 200, headers: noStore,
      body: Data("<title>\(title)</title><body>\(body)</body>".utf8))
  }
}
