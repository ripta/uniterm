import AppKit
import Preferences
import XCTest

@testable import SettingsKit

@MainActor
final class SettingsWindowControllerTests: XCTestCase {
  private var suites: [String] = []

  override func tearDown() async throws {
    for suite in suites {
      UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    suites = []
  }

  private func makeStore(seed: [String: String] = [:]) -> SettingsStore {
    let suite = "uniterm-settings-\(UUID())"
    suites.append(suite)

    let defaults = UserDefaults(suiteName: suite)!
    for (key, value) in seed {
      defaults.set(value, forKey: key)
    }

    return SettingsStore(defaults: defaults)
  }

  private func control(_ identifier: String, in window: NSWindow) -> NSSegmentedControl? {
    func search(_ view: NSView) -> NSSegmentedControl? {
      if let control = view as? NSSegmentedControl, control.accessibilityIdentifier() == identifier
      {
        return control
      }

      for subview in view.subviews {
        if let found = search(subview) { return found }
      }

      return nil
    }

    return window.contentView.flatMap(search)
  }

  /// Catches a Settings window with no status bar row, or a row that does not write the setting.
  func testStatusBarPositionRowWritesTheSetting() throws {
    let store = makeStore()
    let window = try XCTUnwrap(SettingsWindowController(store: store).window)
    let row = try XCTUnwrap(control("status-bar-position-control", in: window))

    XCTAssertEqual(row.segmentCount, 2)
    XCTAssertEqual(row.label(forSegment: 0), "Top")
    XCTAssertEqual(row.label(forSegment: 1), "Bottom")
    XCTAssertEqual(row.selectedSegment, 1, "the default is bottom")

    row.selectedSegment = 0
    _ = row.sendAction(row.action, to: row.target)
    XCTAssertEqual(store.value(of: .statusBarPosition), .top)

    row.selectedSegment = 1
    _ = row.sendAction(row.action, to: row.target)
    XCTAssertEqual(store.reading(of: .statusBarPosition), .valid(.bottom))
  }

  /// Catches a row that rewrites a value it does not understand.
  func testStatusBarPositionRowShowsTheDefaultForAnUnknownValueWithoutWritingIt() throws {
    let store = makeStore(seed: ["statusBarPosition": "sideways"])
    let window = try XCTUnwrap(SettingsWindowController(store: store).window)
    let row = try XCTUnwrap(control("status-bar-position-control", in: window))

    XCTAssertEqual(row.selectedSegment, 1)
    XCTAssertEqual(
      store.reading(of: .statusBarPosition), .invalid(raw: "sideways", fallback: .bottom))
  }

  /// Catches the appearance row going missing in the refactor that added the second row.
  func testAppearanceRowStillWritesTheSetting() throws {
    let store = makeStore()
    let window = try XCTUnwrap(SettingsWindowController(store: store).window)
    let row = try XCTUnwrap(control("appearance-control", in: window))

    XCTAssertEqual(row.segmentCount, 3)
    row.selectedSegment = 2
    _ = row.sendAction(row.action, to: row.target)

    XCTAssertEqual(store.value(of: .appearance), .dark)
  }

  private func note(_ identifier: String, in window: NSWindow) -> NSTextField? {
    subviews(of: NSTextField.self, in: window.contentView!)
      .first { $0.accessibilityIdentifier() == identifier }
  }

  /// Catches a Settings window with no search engine row, a row that lists the wrong engines, or
  /// one that does not write the setting.
  func testSearchEngineRowListsTheEnginesAndWritesTheSetting() throws {
    let store = makeStore()
    let window = try XCTUnwrap(SettingsWindowController(store: store).window)
    let row = try XCTUnwrap(control("search-engine-control", in: window))

    XCTAssertEqual(
      (0..<row.segmentCount).map { row.label(forSegment: $0) ?? "" },
      ["DuckDuckGo", "Google", "Bing", "Ecosia", "Kagi"])
    XCTAssertEqual(row.selectedSegment, 0, "the default is DuckDuckGo")
    XCTAssertEqual(
      note("search-engine-control-note", in: window)?.isHidden, true,
      "a known value showed a note")

    row.selectedSegment = 4
    _ = row.sendAction(row.action, to: row.target)

    XCTAssertEqual(store.reading(of: .searchEngine), .valid(.kagi))
  }

  /// Catches a stored engine that is no longer on the list showing as the default with no word
  /// about it, or a row that writes the default over the stored text. The note names the stored
  /// text and the engine in use.
  func testAStoredEngineThatLeftTheListShowsAsReplacedByTheDefault() throws {
    let store = makeStore(seed: ["searchEngine": "altavista"])
    let window = try XCTUnwrap(SettingsWindowController(store: store).window)
    let row = try XCTUnwrap(control("search-engine-control", in: window))
    let note = try XCTUnwrap(note("search-engine-control-note", in: window))

    XCTAssertEqual(row.selectedSegment, 0)
    XCTAssertFalse(note.isHidden)
    XCTAssertEqual(
      note.stringValue,
      "\u{201C}altavista\u{201D} is not a choice this version has. Using DuckDuckGo.")
    XCTAssertEqual(
      store.reading(of: .searchEngine), .invalid(raw: "altavista", fallback: .duckDuckGo))
  }

  private func subviews<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
    var found: [T] = []

    for subview in view.subviews {
      if let match = subview as? T { found.append(match) }

      found += subviews(of: type, in: subview)
    }

    return found
  }

  /// The alignment rect, which is what Auto Layout aligns. A label's frame reaches a little past it.
  private func frameInWindow(_ view: NSView) -> NSRect {
    view.convert(view.alignmentRect(forFrame: view.bounds), to: nil)
  }

  /// Catches a form whose labels or controls do not line up, a control that runs to the window
  /// edge, and a window that does not fit its rows. Labels must end at one trailing edge and
  /// controls must start at one leading edge. Everything keeps a standard margin from the edges.
  func testRowsShareColumnEdgesAndKeepMargins() throws {
    let window = try XCTUnwrap(SettingsWindowController(store: makeStore()).window)
    let content = try XCTUnwrap(window.contentView)
    content.layoutSubtreeIfNeeded()

    let controls = ["appearance-control", "status-bar-position-control"].map {
      frameInWindow(control($0, in: window)!)
    }
    let labels = subviews(of: NSTextField.self, in: content)
      .filter { ["Appearance:", "Status bar:"].contains($0.stringValue) }
      .map(frameInWindow)
    XCTAssertEqual(labels.count, 2)

    XCTAssertEqual(controls[0].minX, controls[1].minX, accuracy: 0.5, "controls start apart")
    XCTAssertEqual(labels[0].maxX, labels[1].maxX, accuracy: 0.5, "labels end apart")
    XCTAssertLessThan(labels[0].maxX, controls[0].minX, "labels and controls collide")

    let bounds = content.bounds
    for frame in labels + controls {
      XCTAssertGreaterThanOrEqual(frame.minX, 20 - 0.5, "too close to the leading edge")
      XCTAssertLessThanOrEqual(frame.maxX, bounds.maxX - 20 + 0.5, "too close to the trailing edge")
      XCTAssertGreaterThanOrEqual(frame.minY, 20 - 0.5, "too close to the bottom edge")
      XCTAssertLessThanOrEqual(frame.maxY, bounds.maxY - 20 + 0.5, "too close to the top edge")
    }

    XCTAssertEqual(
      content.fittingSize.width, bounds.width, accuracy: 1, "window is not sized to fit")
  }
}
