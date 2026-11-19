import XCTest

@testable import AppletKit

/// The rule for what an event carries to a caller written for an earlier minor. An exec channel
/// applies it to every event it delivers.
final class AppletEventVersionTests: XCTestCase {
  private let early = AppletMessageSchema(
    name: "early", summary: "Always there.",
    arguments: AppletObjectSchema([
      "a": .init(.boolean), "b": .init(.boolean, required: false, since: 2),
    ]))

  private let late = AppletMessageSchema(name: "late", summary: "Added in minor 2.", since: 2)

  private var schema: AppletCommandSchema {
    AppletCommandSchema(
      appletType: "t", version: AppletSchemaVersion(1, 3), commands: [], events: [early, late])
  }

  private let data: [String: JSONValue] = ["a": .bool(true), "b": .bool(false)]

  /// Catches a field cut from a driver that has the minor that added it.
  func testACallerAtOrPastTheFieldsMinorGetsTheField() {
    for minor in [2, 3] {
      XCTAssertEqual(
        early.event(data, deliveredTo: AppletSchemaVersion(1, minor), of: schema), data)
    }
  }

  /// Catches a driver at an earlier minor receiving a field it could not know to ignore.
  func testACallerBeforeTheFieldsMinorGetsTheEventWithoutIt() {
    XCTAssertEqual(
      early.event(data, deliveredTo: AppletSchemaVersion(1, 1), of: schema), ["a": .bool(true)])
  }

  /// Catches an event of a later minor reaching a driver that could not know to ignore the whole
  /// event.
  func testAnEventAddedAfterTheCallersMinorIsNeverSent() {
    XCTAssertNil(late.event([:], deliveredTo: AppletSchemaVersion(1, 1), of: schema))
    XCTAssertEqual(late.event([:], deliveredTo: AppletSchemaVersion(1, 2), of: schema), [:])
  }

  /// Catches a caller written for another major receiving events whose meaning it never agreed to.
  func testACallerOfAnotherMajorGetsNothing() {
    XCTAssertNil(early.event(data, deliveredTo: AppletSchemaVersion(2, 3), of: schema))
    XCTAssertNil(early.event(data, deliveredTo: AppletSchemaVersion(0, 3), of: schema))
  }
}
