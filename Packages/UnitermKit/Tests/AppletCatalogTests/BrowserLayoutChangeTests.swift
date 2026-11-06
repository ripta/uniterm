import AppKit
import AppletKit
import BrowserApplet
import BrowserTestSupport
import Preferences
import WebKit
import XCTest

@testable import BrowserApplet
@testable import WindowKit

/// What a browser pane's history does to the saved layout. The window compares the pane's
/// description with the saved one at every change, and the undo-only part never counts.
@MainActor
final class BrowserLayoutChangeTests: XCTestCase {
  private func changes<Value: Sendable>(
    of keyPath: KeyPath<WKWebView, Value>, in web: WKWebView
  ) -> (stream: AsyncStream<Value>, token: NSKeyValueObservation) {
    let pair = AsyncStream.makeStream(of: Value.self)

    nonisolated(unsafe) let path = keyPath

    let token = web.observe(path, options: [.initial, .new]) { view, _ in
      pair.continuation.yield(view[keyPath: path])
    }

    return (pair.stream, token)
  }

  /// True once a value matches. A value that never arrives fails after `seconds`, so a regression
  /// does not hang the run. The timer ends with the wait.
  private func arrives<Value: Sendable>(
    in stream: AsyncStream<Value>, seconds: Int = 30,
    where match: @escaping @Sendable (Value) -> Bool
  ) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
      group.addTask {
        for await value in stream where match(value) { return true }

        return false
      }

      group.addTask {
        try? await Task.sleep(for: .seconds(seconds))

        return false
      }

      let first = await group.next() ?? false

      group.cancelAll()

      return first
    }
  }

  /// Catches a history change that counts as a layout change. A page pushes a history entry with no
  /// new address stored, so the saved description is the same and the window raises nothing. A
  /// title change is the control: it changes the description, and the window does raise one.
  func testAHistoryOnlyChangeRaisesNoLayoutChangeAndATitleChangeDoes() async throws {
    let suite = "uniterm-browser-layout-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    let store = SettingsStore(defaults: defaults)
    let services = BrowserServices.live(
      searchEngine: { .duckDuckGo },
      directory: FileManager.default.temporaryDirectory
        .appending(path: "uniterm-layout-\(UUID().uuidString)", directoryHint: .isDirectory))
    let server = try await FixtureServer.start()
    defer { server.stop() }

    let applet = BrowserApplet(dataStore: .nonPersistent(), services: services)
    let controller = try MainWindowController(
      appearance: AppearanceController(store: store), settings: store, startingWith: applet,
      makeApplet: { _, _ in BrowserApplet(dataStore: .nonPersistent(), services: services) })
    defer {
      controller.window?.close()
      applet.close()
    }

    XCTAssertNotNil(applet.host, "the window never bound the pane's host")

    applet.start(origin: .user)

    let web = applet.tab.webView

    let titles = changes(of: \.title, in: web)

    applet.submit(address: server.url("/").absoluteString)

    let loaded = await arrives(in: titles.stream) { $0 == "ok" }

    XCTAssertTrue(loaded, "the page never loaded")

    let backs = changes(of: \.canGoBack, in: web)
    var layoutChanges = 0

    controller.onLayoutChange = { layoutChanges += 1 }
    _ = controller.savedWindow()
    layoutChanges = 0

    _ = try? await web.evaluateJavaScript("history.pushState({}, '', '/pushed')")

    let pushed = await arrives(in: backs.stream) { $0 }

    XCTAssertTrue(pushed, "the history entry never showed")

    applet.host?.appletDidChange(applet)

    XCTAssertEqual(layoutChanges, 0, "a history entry alone raised a layout change")

    _ = try? await web.evaluateJavaScript("document.title = 'two'")

    let retitled = await arrives(in: titles.stream) { $0 == "two" }

    XCTAssertTrue(retitled, "the title never changed")

    XCTAssertGreaterThan(layoutChanges, 0, "a title change raised no layout change")
    backs.token.invalidate()
    titles.token.invalidate()
  }
}
