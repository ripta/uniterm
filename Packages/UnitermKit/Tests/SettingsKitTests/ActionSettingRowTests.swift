import AppKit
import Preferences
import XCTest

@testable import SettingsKit

/// The row that runs an action from Settings. A run that is in flight blocks a second one, a failure
/// never reads as a success, and the host's closure is the only thing that does the work.
@MainActor
final class ActionSettingRowTests: XCTestCase {
  private struct Refused: LocalizedError {
    var errorDescription: String? { "The store is busy." }
  }

  @MainActor
  private final class Switch {
    var fails = true
  }

  private func makeRow(
    _ action: @escaping @MainActor () async throws -> Void
  ) -> ActionSettingRow {
    ActionSettingRow(
      caption: "Data:", buttonTitle: "Clear", note: "Open tabs keep their session.",
      succeededText: "Cleared.", identifier: "row", action: action)
  }

  /// Catches a double click that starts a second clear, and a button that stays enabled while one
  /// runs. The closure holds at a gate the test opens. A click sent past the disabled button, which
  /// stands for any other caller, still starts nothing.
  func testASecondRunDoesNotStartWhileOneIsInFlight() async throws {
    let gate = AsyncStream.makeStream(of: Void.self)
    var runs = 0

    let row = makeRow {
      runs += 1

      for await _ in gate.stream { return }
    }

    row.perform()

    XCTAssertEqual(row.state, .running)
    XCTAssertFalse(row.button.isEnabled)
    XCTAssertFalse(row.status.isHidden)

    row.perform()
    _ = row.button.sendAction(row.button.action, to: row.button.target)

    gate.continuation.yield()
    await row.running?.value

    XCTAssertEqual(runs, 1)
    XCTAssertEqual(row.state, .succeeded)
    XCTAssertEqual(row.status.stringValue, "Cleared.")
    XCTAssertTrue(row.button.isEnabled)
  }

  /// Catches a failed clear that looks like a success. The row names the reason, never says
  /// "Cleared.", gives the button back, and a retry that works replaces the failure.
  func testAFailureShowsItsReasonAndARetryCanSucceed() async throws {
    let toggle = Switch()

    let row = makeRow {
      if toggle.fails { throw Refused() }
    }

    row.perform()
    await row.running?.value

    XCTAssertEqual(row.state, .failed("The store is busy."))
    XCTAssertEqual(row.status.stringValue, "The store is busy.")
    XCTAssertFalse(row.status.stringValue.contains("Cleared."))
    XCTAssertTrue(row.button.isEnabled)

    toggle.fails = false
    row.perform()
    await row.running?.value

    XCTAssertEqual(row.state, .succeeded)
    XCTAssertEqual(row.status.stringValue, "Cleared.")
  }

  /// Catches a row with no outcome line before the first run, or one that asks a question. The row
  /// starts quiet, with the note showing.
  func testTheRowStartsIdleWithItsNoteAndNoOutcome() {
    let row = makeRow {}

    XCTAssertEqual(row.state, .idle)
    XCTAssertTrue(row.status.isHidden)
    XCTAssertEqual(row.note.stringValue, "Open tabs keep their session.")
    XCTAssertTrue(row.button.isEnabled)
  }

  /// Catches a Settings window with no Clear Website Data button, a button wired to nothing, or a
  /// note that leaves out what an open tab keeps. A click reaches the host's closure.
  func testTheSettingsWindowOffersClearWebsiteDataAndSaysOpenTabsKeepTheirSession() async throws {
    let suite = "uniterm-settings-\(UUID())"
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

    let store = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
    let called = expectation(description: "the host's closure ran")
    let controller = SettingsWindowController(
      store: store, clearWebsiteData: { called.fulfill() })
    let content = try XCTUnwrap(controller.window?.contentView)

    func find<V: NSView>(_ type: V.Type, _ identifier: String) -> V? {
      var queue: [NSView] = [content]

      while let view = queue.popLast() {
        if let match = view as? V, match.accessibilityIdentifier() == identifier { return match }

        queue += view.subviews
      }

      return nil
    }

    let button = try XCTUnwrap(find(NSButton.self, "clear-website-data-button"))
    let note = try XCTUnwrap(find(NSTextField.self, "clear-website-data-note"))

    XCTAssertEqual(button.title, "Clear Website Data")
    XCTAssertTrue(note.stringValue.contains("Open tabs keep their current session"))
    XCTAssertTrue(note.stringValue.contains("reloaded or closed"))

    button.performClick(nil)

    await fulfillment(of: [called], timeout: 5)
  }
}
