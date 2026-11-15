import AppKit
import Preferences
import ScriptHost
import XCTest

@testable import WindowKit

@MainActor
final class PendingRequestsTests: XCTestCase {
  private let suite = "uniterm-pending-requests-test-\(UUID().uuidString)"
  private var windows: WindowSet!
  private var indicator: PendingRequestsIndicator!

  override func setUp() async throws {
    let store = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
    let appearance = AppearanceController(store: store)

    windows = WindowSet(
      visibleFrame: { _ in NSRect(x: 0, y: 0, width: 4000, height: 3000) },
      makeRestoredController: { identifier, restored in
        try MainWindowController(
          appearance: appearance, settings: store, identifier: identifier, restoring: restored,
          restoreApplet: { _ in FakeApplet() }, makeApplet: { _, _ in FakeApplet() }
        ).detachFromRealScreen()
      },
      makeController: { identifier, directory in
        try MainWindowController(
          appearance: appearance, settings: store, identifier: identifier, startingIn: directory,
          makeApplet: { _, _ in FakeApplet() }
        ).detachFromRealScreen()
      })

    _ = try windows.open()
    indicator = PendingRequestsIndicator(windows: windows, scriptHost: { nil })
  }

  override func tearDown() async throws {
    for controller in windows.controllers { controller.window?.close() }

    UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    windows = nil
    indicator = nil
  }

  private var postedTexts: [String] {
    windows.activeController?.statusCenter.history.map(\.text) ?? []
  }

  private func ask(_ power: String, subject: String = "build.janet, PID 42") {
    _ = windows.permissionRequests.ask(
      .init(requester: .terminal(window: 1, pane: 1), power: power), subject: subject,
      title: "Read the clipboard", detail: "", sessionTitle: "Allow for This Session",
      answer: { _ in })
  }

  /// Catches a slot without a count, a count that includes a row's repeated operations, an arrival
  /// that posts nothing, and a refresh that posts the same row again. Each new row posts once.
  /// Asking again under the same row, or refreshing with nothing new, posts nothing.
  func testEachNewRowPostsOnceAndTheSlotCountsRows() throws {
    ask("clipboard-read")
    indicator.refresh()

    XCTAssertEqual(windows.windowStates.label(of: .pendingPermissions), "1 request")
    XCTAssertEqual(
      postedTexts, ["Pending request: build.janet, PID 42 asks: Read the clipboard."])

    ask("clipboard-read")
    indicator.refresh()
    indicator.refresh()

    XCTAssertEqual(windows.windowStates.label(of: .pendingPermissions), "1 request")
    XCTAssertEqual(postedTexts.count, 1, "a repeated question posted again")

    ask("clipboard-write")
    indicator.refresh()

    XCTAssertEqual(windows.windowStates.label(of: .pendingPermissions), "2 requests")
    XCTAssertEqual(postedTexts.count, 2)
  }

  /// Catches a slot that stays once nothing waits, or that counts a denial. A denial is listed in
  /// the panel but asks nothing.
  func testTheSlotClearsWhenTheLastRowIsAnsweredAndADenialIsNotCounted() throws {
    ask("clipboard-read")
    indicator.refresh()

    let row = try XCTUnwrap(windows.permissionRequests.rows.first)
    windows.permissionRequests.decide(row.id, .deny)
    indicator.refresh()

    XCTAssertFalse(windows.permissionRequests.denials.isEmpty)
    XCTAssertNil(windows.windowStates.text(of: .pendingPermissions))
  }

  // MARK: Panel buttons

  private func makePanel() throws -> (panel: PendingRequestsWindowController, table: NSTableView) {
    let panel = PendingRequestsWindowController(scriptHost: nil, windows: windows)
    let content = try XCTUnwrap(panel.window?.contentView)

    content.layoutSubtreeIfNeeded()

    return (panel, try XCTUnwrap(content.firstDescendant(of: NSTableView.self)))
  }

  /// The titles of the panel's buttons that show, in the order they sit.
  private func shownButtons(_ panel: PendingRequestsWindowController) throws -> [String] {
    let content = try XCTUnwrap(panel.window?.contentView)

    return content.descendants(of: NSButton.self)
      .filter { !$0.isHiddenOrHasHiddenAncestor && $0.bezelStyle != .helpButton }
      .map(\.title)
  }

  private func detailText(_ panel: PendingRequestsWindowController) throws -> String {
    let content = try XCTUnwrap(panel.window?.contentView)
    let detail = content.descendants(of: NSTextField.self)
      .first { $0.accessibilityIdentifier() == "pending-requests-detail" }

    return try XCTUnwrap(detail).stringValue
  }

  /// Catches buttons that show for a row kind they cannot answer, or that show disabled with
  /// nothing selected. An empty panel and an unselected row show no button, and the detail says
  /// what to do. A question shows its own answers, and nothing else, every one of them live.
  func testThePanelShowsOnlyTheSelectedRowsButtons() throws {
    let (panel, table) = try makePanel()

    XCTAssertEqual(try shownButtons(panel), [])
    XCTAssertEqual(try detailText(panel), "Nothing waits for your answer.")

    ask("clipboard-read")

    XCTAssertEqual(try shownButtons(panel), [])
    XCTAssertEqual(try detailText(panel), "Select a request to answer it.")

    table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

    XCTAssertEqual(try shownButtons(panel), ["Allow Once", "Allow for This Session", "Deny"])

    let content = try XCTUnwrap(panel.window?.contentView)
    let shown = content.descendants(of: NSButton.self).filter { !$0.isHiddenOrHasHiddenAncestor }
    XCTAssertTrue(shown.allSatisfy(\.isEnabled), "a shown button is disabled")

    let row = try XCTUnwrap(windows.permissionRequests.rows.first)
    windows.permissionRequests.decide(row.id, .deny)
    table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

    XCTAssertEqual(try shownButtons(panel), ["Ask Again"])
  }
}

extension NSView {
  fileprivate func descendants<T: NSView>(of type: T.Type) -> [T] {
    subviews.flatMap { ($0 as? T).map { [$0] } ?? [] }
      + subviews.flatMap { $0.descendants(of: type) }
  }

  fileprivate func firstDescendant<T: NSView>(of type: T.Type) -> T? {
    descendants(of: type).first
  }
}
