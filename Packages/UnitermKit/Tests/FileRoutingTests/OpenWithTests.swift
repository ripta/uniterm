import AppKit
import AppletKit
import XCTest

@testable import FileRouting

/// Proves the saved-choice store and the chooser model against an isolated defaults suite. The
/// rule that no controller or script can write a choice is structural: the writers are
/// file-private. A test cannot prove a call fails to compile, so it proves what the store does
/// with entries it did not write.
@MainActor
final class OpenWithTests: XCTestCase {
  private var suite = ""
  private var defaults: UserDefaults!
  private var store: SavedChoiceStore!

  private let key = SavedChoiceStore.defaultsKey
  private let type = "com.example.geojson"
  private let candidates = [
    applet("map", [("com.example.geojson", .alternate)]),
    applet("data", [("public.text", .owner)]),
  ]

  override func setUp() async throws {
    suite = "uniterm-openwith-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suite)
    store = SavedChoiceStore(defaults: defaults)

    let suite = suite
    addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
  }

  private func model() throws -> OpenWithModel {
    try XCTUnwrap(
      OpenWithModel(
        file: URL(fileURLWithPath: "/tmp/a.geojson"), type: type, candidates: candidates,
        store: store))
  }

  /// Catches a chooser that does not save the pick, or saves it under the wrong type.
  func testASavedChoiceRoundTripsThroughTheStore() throws {
    let first = try model()
    first.selection = "data"
    first.alwaysUse = true

    XCTAssertEqual(first.confirm(), "data")
    XCTAssertEqual(store.choices(), [type: "data"])

    let second = try model()
    XCTAssertEqual(second.savedAppletTypeID, "data")
    XCTAssertEqual(second.selection, "data")
  }

  /// Catches a pick that saves when the user did not ask.
  func testAPickWithoutAlwaysUseSavesNothing() throws {
    let chooser = try model()
    chooser.selection = "data"

    XCTAssertEqual(chooser.confirm(), "data")
    XCTAssertNil(defaults.object(forKey: key))
  }

  /// Catches a clear that leaves the entry, and one that disturbs other entries.
  func testClearingRemovesOnlyThatEntry() throws {
    defaults.set([type: "map", "public.json": "data"], forKey: key)

    let chooser = try model()
    XCTAssertTrue(chooser.hasStoredChoice)

    chooser.clearSavedChoice()

    XCTAssertEqual(store.choices(), ["public.json": "data"])
    XCTAssertNil(chooser.savedAppletTypeID)
  }

  /// Catches a store that drops or rewrites entries it cannot decode. An older or newer build owns
  /// those entries, and a read must never write.
  func testCorruptAndUnknownEntriesAreIgnoredAndKeptOnDisk() throws {
    let stored: [String: Any] = [
      "public.json": "data", "public.text": 42, "": "map", "public.data": "",
      "public.xml": ["nested": "value"], "com.example.future": "applet-from-the-future",
    ]
    defaults.set(stored, forKey: key)

    XCTAssertEqual(
      store.choices(), ["public.json": "data", "com.example.future": "applet-from-the-future"])
    XCTAssertEqual(defaults.dictionary(forKey: key)?.count, stored.count)

    let chooser = try model()
    chooser.selection = "data"
    chooser.alwaysUse = true
    _ = chooser.confirm()

    let after = try XCTUnwrap(defaults.dictionary(forKey: key))
    XCTAssertEqual(after.count, stored.count + 1)
    XCTAssertEqual(after["public.text"] as? Int, 42)
    XCTAssertEqual((after["public.xml"] as? [String: String])?["nested"], "value")
  }

  /// Catches a store that crashes or rewrites when the key holds something that is not a
  /// dictionary.
  func testAValueThatIsNotADictionaryReadsAsEmptyAndStays() {
    defaults.set("garbage", forKey: key)

    XCTAssertEqual(store.choices(), [:])
    XCTAssertEqual(defaults.string(forKey: key), "garbage")
  }

  /// Catches a stale choice that cannot be cleared because its applet is gone.
  func testAStoredChoiceNamingAMissingAppletCanStillBeCleared() throws {
    defaults.set([type: "gone"], forKey: key)

    let chooser = try model()
    XCTAssertNil(chooser.savedAppletTypeID)
    XCTAssertTrue(chooser.hasStoredChoice)
    XCTAssertEqual(chooser.selection, "map")

    chooser.clearSavedChoice()
    XCTAssertEqual(store.choices(), [:])
  }

  func testNoCandidatesMeansNoChooser() {
    XCTAssertNil(
      OpenWithModel(file: URL(fileURLWithPath: "/a"), type: type, candidates: [], store: store))
  }

  func testADynamicTypeCannotBeSaved() throws {
    let chooser = try XCTUnwrap(
      OpenWithModel(
        file: URL(fileURLWithPath: "/a.zzz"), type: "dyn.age80", candidates: candidates,
        store: store))
    chooser.alwaysUse = true
    _ = chooser.confirm()

    XCTAssertNil(defaults.object(forKey: key))
  }

  // MARK: Alert

  /// Catches a chooser that lacks a way to clear, or offers one when there is nothing to clear.
  func testTheAlertOffersClearOnlyWhenAChoiceIsStored() throws {
    let plain = OpenWithChooser(model: try model()).makeAlert()
    XCTAssertEqual(plain.buttons.map(\.title), ["Open", "Cancel"])

    defaults.set([type: "map"], forKey: key)
    let stored = OpenWithChooser(model: try model()).makeAlert()
    XCTAssertEqual(stored.buttons.map(\.title), ["Open", "Cancel", "Clear Saved Choice"])
  }

  /// Catches a chooser whose list differs from the applets that declare the type.
  func testTheAlertListsEveryCandidate() throws {
    let alert = OpenWithChooser(model: try model()).makeAlert()
    let stack = try XCTUnwrap(alert.accessoryView as? NSStackView)
    let popUp = try XCTUnwrap(stack.views.first as? NSPopUpButton)

    XCTAssertEqual(popUp.itemTitles, ["Map", "Data"])
  }

  func testSettlingMapsEachButtonToItsOutcome() throws {
    let model = try model()
    let chooser = OpenWithChooser(model: model)

    XCTAssertEqual(chooser.settle(.alertSecondButtonReturn), .cancelled)
    XCTAssertEqual(chooser.settle(.alertFirstButtonReturn), .open(appletTypeID: "map"))

    defaults.set([type: "map"], forKey: key)
    XCTAssertEqual(chooser.settle(.alertThirdButtonReturn), .clearedSavedChoice)
    XCTAssertEqual(store.choices(), [:])
  }
}
