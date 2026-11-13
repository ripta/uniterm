import AppKit
import Preferences
import ScriptHost
import XCTest

@testable import WindowKit

@MainActor
final class PendingRequestsIndicatorTests: XCTestCase {
  private let suite = "uniterm-pending-indicator-test-\(UUID().uuidString)"
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
}
