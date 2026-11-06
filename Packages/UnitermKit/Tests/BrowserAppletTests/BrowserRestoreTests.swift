import AppletKit
import BrowserModel
import XCTest

@testable import BrowserApplet

/// Restoring from a description, and the description's rules for version and shape. A description
/// this build cannot read is refused, so the host keeps its bytes.
@MainActor
final class BrowserRestoreTests: XCTestCase {
  private func restore(version: Int = 1, type: String = "browser", payload: JSONValue) throws {
    _ = try BrowserApplet(
      restoring: AppletDescription(type: type, version: version, payload: payload),
      dataStore: .nonPersistent(), services: .testing())
  }

  private func valid() throws -> JSONValue {
    try JSONValue(encoding: BrowserDescription())
  }

  /// Catches a newer description restored as if it were version 1, which would drop its fields on
  /// the next write.
  func testANewerVersionIsRefusedForTheHostToKeep() throws {
    XCTAssertThrowsError(try restore(version: 2, payload: valid())) { error in
      XCTAssertEqual(error as? AppletRestoreError, .newerVersion(found: 2, supported: 1))
    }
  }

  /// Catches a newer description that this build cannot read being reported as damage, which the
  /// host would treat as a broken pane and not as another build's state to keep byte for byte.
  func testANewerVersionWithAnUnreadablePayloadIsStillNewer() throws {
    XCTAssertThrowsError(try restore(version: 2, payload: .string("a shape from a later build"))) {
      error in
      XCTAssertEqual(error as? AppletRestoreError, .newerVersion(found: 2, supported: 1))
    }
  }

  func testADescriptionOfAnotherTypeIsRefused() throws {
    XCTAssertThrowsError(try restore(type: "map-viewer", payload: valid())) { error in
      XCTAssertEqual(
        error as? AppletRestoreError, .wrongType(expected: "browser", found: "map-viewer"))
    }
  }

  /// Catches damaged payloads that crash or restore as something else: a missing tab list, an empty
  /// one, and a selection past the end.
  func testDamagedPayloadsAreRefusedAsCorrupt() throws {
    let damaged: [JSONValue] = [
      .object([:]),
      .object(["tabs": .array([]), "selected": .number(0)]),
      .object(["tabs": .array([.object([:])]), "selected": .number(3)]),
      .string("nope"),
    ]

    for payload in damaged {
      XCTAssertThrowsError(try restore(payload: payload)) { error in
        guard case .corrupt = error as? AppletRestoreError else {
          return XCTFail("expected corrupt, got \(error)")
        }
      }
    }
  }

  /// Catches a description that stops round-tripping through the applet: a blank pane describes as
  /// one empty tab, and a restored pane describes what it was given.
  func testTheDescriptionRoundTrips() throws {
    let blank = BrowserApplet(dataStore: .nonPersistent(), services: .testing())
    defer { blank.close() }

    XCTAssertEqual(blank.describe().payload, try valid())
    XCTAssertNil(blank.currentDirectory)

    let given = BrowserDescription(
      tabs: [.init(url: "https://example.com", title: "E")], selected: 0)
    let payload = try JSONValue(encoding: given)
    let restored = try BrowserApplet(
      restoring: AppletDescription(type: "browser", version: 1, payload: payload),
      dataStore: .nonPersistent(), services: .testing())
    defer { restored.close() }

    XCTAssertEqual(restored.describe().payload, payload)
    XCTAssertEqual(restored.describe().version, 1)
  }

  /// Catches a toolbar whose buttons are enabled until the web view first reports a change, which
  /// a tab that has loaded nothing never does. A new pane and a restored pane both start with Back
  /// and Forward off.
  func testBackAndForwardStartOffBeforeAnythingLoads() throws {
    let blank = BrowserApplet(dataStore: .nonPersistent(), services: .testing())
    defer { blank.close() }

    XCTAssertFalse(blank.content.backButton.isEnabled)
    XCTAssertFalse(blank.content.forwardButton.isEnabled)

    let restored = try BrowserApplet(
      restoring: AppletDescription(type: "browser", version: 1, payload: try valid()),
      dataStore: .nonPersistent(), services: .testing())
    defer { restored.close() }

    XCTAssertFalse(restored.content.backButton.isEnabled)
    XCTAssertFalse(restored.content.forwardButton.isEnabled)
  }

  func testTheDeclarationOpensNoFile() {
    XCTAssertEqual(BrowserApplet.typeDeclaration.typeID, "browser")
    XCTAssertTrue(BrowserApplet.typeDeclaration.opens.isEmpty)
  }
}
