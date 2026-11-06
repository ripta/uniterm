import Foundation
import GeoData
import XCTest

@testable import MapViewerApplet

/// The reader on `MKGeoJSONDecoder` as shipped. It proves what the decoder hands the extraction.
final class GeoJSONFileReaderTests: XCTestCase {
  private func layer(_ text: String, limits: GeoJSONLimits = GeoJSONLimits()) throws -> GeoFileLayer
  {
    try GeoJSONFileReader.layer(from: Data(text.utf8), path: "/x.geojson", limits: limits).get()
  }

  /// Catches a decoder shape that the extraction mistakes for a point. Point and MultiPoint become
  /// pins. A LineString, a Polygon, a MultiPolygon, a feature with no geometry, and a geometry
  /// collection of a line are skipped. A polyline is an `MKMultiPoint` subclass, so it is the case
  /// most likely to turn into pins by mistake. The builder's tests take plain values. This one owns
  /// the MapKit side, since only here do real decoded objects, polyline subclasses included, arrive.
  func testOnlyPointAndMultiPointBecomePins() throws {
    let nothing = #"{"type":"Feature","properties":{},"geometry":null}"#
    let multiPolygon =
      #"{"type":"Feature","properties":{},"geometry":{"type":"MultiPolygon","coordinates":[[[[0,0],[1,0],[1,1],[0,0]]]]}}"#

    let result = try layer(
      GeoFixtures.collection([
        GeoFixtures.point("A", 1, 2), GeoFixtures.multiPoint, GeoFixtures.line,
        GeoFixtures.polygon, multiPolygon, nothing,
      ]))

    XCTAssertEqual(result.pins.map(\.id), ["0:0", "1:0", "1:1"])
    XCTAssertEqual(result.skippedShapes, 4)
    XCTAssertEqual(result.pins[0].coordinate.latitude, 2, accuracy: 1e-9)
    XCTAssertEqual(result.pins[0].coordinate.longitude, 1, accuracy: 1e-9)
    XCTAssertEqual(result.pins[1].coordinate.latitude, 20, accuracy: 1e-9)
    XCTAssertEqual(result.pins[1].coordinate.longitude, 10, accuracy: 1e-9)
  }

  /// Catches a bare geometry that the decoder returns as a shape and the reader drops. A top-level
  /// Point is a pin with the coordinate text for a label.
  func testABareGeometryIsAnObject() throws {
    let result = try layer(#"{"type":"Point","coordinates":[10,20]}"#)

    XCTAssertEqual(result.pins.map(\.id), ["0:0"])
    XCTAssertEqual(result.pins.first?.label, "20.00000, 10.00000")
  }

  /// Catches text that is not GeoJSON passing as an empty map. The error says it is not valid
  /// GeoJSON and never says corrupt.
  func testTextThatIsNotGeoJSONFails() {
    for text in ["", "{", "null"] {
      guard
        case .failure(let error) = GeoJSONFileReader.layer(
          from: Data(text.utf8), path: "/x.geojson", limits: GeoJSONLimits())
      else { return XCTFail("\(text) loaded") }

      XCTAssertTrue(error.errorDescription?.contains("is not valid GeoJSON") ?? false, text)
      XCTAssertFalse(error.errorDescription?.lowercased().contains("corrupt") ?? true)
    }
  }
}
