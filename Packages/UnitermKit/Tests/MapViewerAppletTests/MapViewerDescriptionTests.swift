import AppletKit
import GeoData
import XCTest

@testable import MapViewerApplet

/// The saved payload. ADR-06 makes the applet own its version and refuse what it cannot read.
final class MapViewerDescriptionTests: XCTestCase {
  private let region = GeoRegion(
    center: GeoCoordinate(latitude: 37.5, longitude: -122.25),
    span: GeoSpan(latitudeDelta: 0.5, longitudeDelta: 0.75))

  private var full: MapViewerDescription {
    MapViewerDescription(
      startDirectory: "/work", region: region, style: .hybrid, fileAccent: "mauve",
      path: "/work/places.geojson", bookmark: Data([1, 2, 3]), commandLayerCount: 2)
  }

  /// Catches a payload that loses a field on the way to the layout file. The round trip keeps
  /// every field, including the ones only later sources write.
  func testEveryFieldSurvivesARoundTripThroughTheLayoutJSON() throws {
    let description = try full.appletDescription()

    XCTAssertEqual(description.type, "map-viewer")
    XCTAssertEqual(description.version, 1)

    let data = try JSONEncoder().encode(description)
    let decoded = try JSONDecoder().decode(AppletDescription.self, from: data)

    XCTAssertEqual(try MapViewerDescription.decode(decoded), full)
  }

  /// Catches a stored key that is added, dropped, or renamed without a deliberate edit. The keys
  /// are the contract with every layout file users already have. Adding one bumps the version.
  func testThePayloadKeysAreTheStoredContract() throws {
    guard case .object(let fields) = try full.appletDescription().payload else {
      return XCTFail("not an object")
    }

    XCTAssertEqual(
      Set(fields.keys),
      [
        "startDirectory", "region", "style", "fileAccent", "path", "bookmark",
        "commandLayerCount",
      ])

    XCTAssertEqual(fields["style"], .string("hybrid"))
    XCTAssertEqual(fields["commandLayerCount"], .number(2))

    guard case .object(let stored)? = fields["region"],
      case .object(let center)? = stored["center"], case .object(let span)? = stored["span"]
    else { return XCTFail("the region has no center and span") }

    XCTAssertEqual(Set(stored.keys), ["center", "span"])
    XCTAssertEqual(Set(center.keys), ["latitude", "longitude"])
    XCTAssertEqual(Set(span.keys), ["latitudeDelta", "longitudeDelta"])
  }

  /// Catches an empty pane that forgets where it started, and a fresh pane whose payload holds a
  /// pin source it never had. The style and the count are always written.
  func testAnEmptyPaneStoresItsStartDirectoryAndNothingElse() throws {
    let empty = try MapViewerDescription(startDirectory: "/work").appletDescription()

    guard case .object(let fields) = empty.payload else { return XCTFail("not an object") }

    XCTAssertEqual(Set(fields.keys), ["startDirectory", "style", "commandLayerCount"])
    XCTAssertEqual(try MapViewerDescription.decode(empty).startDirectory, "/work")
    XCTAssertEqual(try MapViewerDescription.decode(empty).style, .standard)
  }

  /// Catches a stored style from a newer build that makes the pane unreadable. It shows the
  /// standard map. The next save writes `standard`, which is why a build adding a style bumps
  /// the version.
  func testAnUnknownStyleIsTheStandardMapAndNotDamage() throws {
    let description = AppletDescription(
      type: "map-viewer", version: 1, payload: .object(["style": .string("terrain")]))

    XCTAssertEqual(try MapViewerDescription.decode(description).style, .standard)
  }

  /// Catches a payload without a style or a count that is refused, as a layout written by a
  /// source that never filled them would be.
  func testAbsentKeysTakeTheirDefaults() throws {
    let description = AppletDescription(type: "map-viewer", version: 1, payload: .object([:]))
    let decoded = try MapViewerDescription.decode(description)

    XCTAssertEqual(decoded, MapViewerDescription())
  }

  /// Catches a newer payload that is read as if it were this version, which would drop its fields
  /// on the next save, and a description of another type.
  func testANewerVersionAndAnotherTypeAreRefused() {
    let newer = AppletDescription(type: "map-viewer", version: 2, payload: .object([:]))

    XCTAssertThrowsError(try MapViewerDescription.decode(newer)) {
      XCTAssertEqual($0 as? AppletRestoreError, .newerVersion(found: 2, supported: 1))
    }

    let other = AppletDescription(type: "data-viewer", version: 1, payload: .object([:]))

    XCTAssertThrowsError(try MapViewerDescription.decode(other)) {
      XCTAssertEqual(
        $0 as? AppletRestoreError, .wrongType(expected: "map-viewer", found: "data-viewer"))
    }
  }

  /// Catches a damaged payload that restores. A wrong shape, a relative path, an out-of-range
  /// region, and a negative count are all corrupt.
  func testADamagedPayloadIsCorrupt() {
    let badRegion = JSONValue.object([
      "center": .object(["latitude": .number(95), "longitude": .number(0)]),
      "span": .object(["latitudeDelta": .number(1), "longitudeDelta": .number(1)]),
    ])

    for payload in [
      JSONValue.string("x"), .object(["path": .number(3)]), .object(["path": .string("rel.json")]),
      .object(["startDirectory": .string("rel")]), .object(["region": badRegion]),
      .object(["style": .number(3)]), .object(["commandLayerCount": .number(-1)]),
    ] {
      let description = AppletDescription(type: "map-viewer", version: 1, payload: payload)

      XCTAssertThrowsError(try MapViewerDescription.decode(description)) {
        guard case .corrupt? = $0 as? AppletRestoreError else {
          return XCTFail("expected corrupt for \(payload)")
        }
      }
    }
  }
}
