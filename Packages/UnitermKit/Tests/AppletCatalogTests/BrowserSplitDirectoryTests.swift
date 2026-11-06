import AppKit
import AppletKit
import BrowserApplet
import Preferences
import XCTest

@testable import WindowKit

/// What a pane split from a browser starts in. The window asks the focused applet for a directory
/// and passes the answer to the factory, so the test runs a real browser pane in a real window.
@MainActor
final class BrowserSplitDirectoryTests: XCTestCase {
  /// Catches a split from a browser that starts the new pane in a directory a library remembers, or
  /// in one the browser invented. The browser reports none, so the factory is asked to start in the
  /// launcher's default. The factory must have run, or the test proves nothing.
  func testAPaneSplitFromABrowserAsksTheFactoryForNoDirectory() throws {
    let suite = "uniterm-browser-split-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    let store = SettingsStore(defaults: defaults)
    let services = BrowserServices.live(
      searchEngine: { .duckDuckGo },
      directory: FileManager.default.temporaryDirectory
        .appending(path: "uniterm-split-\(UUID().uuidString)", directoryHint: .isDirectory))

    var requested: [String?] = []
    var made: [BrowserApplet] = []

    let first = BrowserApplet(dataStore: .nonPersistent(), services: services)
    made.append(first)

    let controller = try MainWindowController(
      appearance: AppearanceController(store: store), settings: store, startingWith: first,
      makeApplet: { _, directory in
        requested.append(directory)

        let applet = BrowserApplet(dataStore: .nonPersistent(), services: services)
        made.append(applet)
        return applet
      })
    defer {
      controller.window?.close()

      for applet in made { applet.close() }
    }

    XCTAssertNil(first.currentDirectory)
    XCTAssertNil(controller.focusedDirectory)

    let second = controller.openPane(.terminalShell, axis: .row, from: controller.focusedPane)

    XCTAssertNotNil(second, "the split did not open")
    XCTAssertEqual(made.count, 2, "the factory never ran")
    XCTAssertEqual(requested.count, 1)
    XCTAssertEqual(requested.first ?? "set", nil)
  }
}
