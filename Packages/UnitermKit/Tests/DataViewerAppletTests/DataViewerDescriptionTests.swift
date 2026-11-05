import AppletKit
import TableData
import XCTest

@testable import DataViewerApplet

/// The saved payload. ADR-06 makes the applet own its version and refuse what it cannot read.
final class DataViewerDescriptionTests: XCTestCase {
  private let full = DataViewerDescription(
    startDirectory: "/data", path: "/data/a.csv", bookmark: Data([1, 2, 3]), sheet: "Q1",
    sort: SortSpec(column: .named("amount", occurrence: 1), ascending: false), filter: "x")

  /// Catches a payload that loses a field on the way to the layout file, or that stores rows. The
  /// round trip keeps every field, including the sheet from the first version.
  func testEveryFieldSurvivesARoundTripThroughTheLayoutJSON() throws {
    let description = try full.appletDescription()

    XCTAssertEqual(description.type, "data-viewer")
    XCTAssertEqual(description.version, 1)

    let data = try JSONEncoder().encode(description)
    let decoded = try JSONDecoder().decode(AppletDescription.self, from: data)

    XCTAssertEqual(try DataViewerDescription.decode(decoded), full)
  }

  /// Catches a payload with a hand-written shape drifting from the one in the layout files users
  /// already have. The keys are the stored contract.
  func testThePayloadKeysAreTheStoredContract() throws {
    let payload = try full.appletDescription().payload

    guard case .object(let fields) = payload else { return XCTFail("not an object") }

    XCTAssertEqual(
      Set(fields.keys), ["startDirectory", "path", "bookmark", "sheet", "sort", "filter"])

    guard case .object(let sort)? = fields["sort"], case .object(let column)? = sort["column"]
    else { return XCTFail("sort has no column") }

    XCTAssertEqual(sort["ascending"], .bool(false))
    XCTAssertEqual(column["segments"], .array([.string("amount")]))
    XCTAssertEqual(column["occurrence"], .number(1))
  }

  /// Catches an empty pane that forgets where it started.
  func testAnEmptyDescriptionStillHoldsTheStartDirectory() throws {
    let empty = try DataViewerDescription(startDirectory: "/work").appletDescription()

    XCTAssertEqual(try DataViewerDescription.decode(empty).startDirectory, "/work")
  }

  /// Catches a newer payload that is read as if it were this version, which would drop its fields
  /// on the next save, and a description of another type.
  func testANewerVersionAndAnotherTypeAreRefused() throws {
    let newer = AppletDescription(type: "data-viewer", version: 2, payload: .object([:]))

    XCTAssertThrowsError(try DataViewerDescription.decode(newer)) {
      XCTAssertEqual($0 as? AppletRestoreError, .newerVersion(found: 2, supported: 1))
    }

    let other = AppletDescription(type: "terminal", version: 1, payload: .object([:]))

    XCTAssertThrowsError(try DataViewerDescription.decode(other)) {
      XCTAssertEqual(
        $0 as? AppletRestoreError, .wrongType(expected: "data-viewer", found: "terminal"))
    }
  }

  /// Catches a damaged payload that restores. A wrong shape and a relative path are both corrupt.
  func testADamagedPayloadIsCorrupt() {
    for payload in [
      JSONValue.string("x"), .object(["path": .number(3)]), .object(["path": .string("rel.csv")]),
      .object(["startDirectory": .string("rel")]),
    ] {
      let description = AppletDescription(type: "data-viewer", version: 1, payload: payload)

      XCTAssertThrowsError(try DataViewerDescription.decode(description)) {
        guard case .corrupt? = $0 as? AppletRestoreError else {
          return XCTFail("expected corrupt for \(payload)")
        }
      }
    }
  }
}
