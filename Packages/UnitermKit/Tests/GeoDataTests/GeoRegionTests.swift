import XCTest

@testable import GeoData

/// The rules that keep a region safe to hand to MapKit.
final class GeoRegionTests: XCTestCase {
  private func region(
    _ latitude: Double, _ longitude: Double, _ latitudeDelta: Double = 1,
    _ longitudeDelta: Double = 2
  ) -> GeoRegion? {
    GeoRegion(
      center: GeoCoordinate(latitude: latitude, longitude: longitude),
      span: GeoSpan(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta))
  }

  /// Catches a region that MapKit would raise an exception on. A non-finite value, a center
  /// latitude off the globe, and a span of zero or less all fail.
  func testRegionsMapKitCannotTakeAreRefused() {
    XCTAssertNotNil(region(37.77, -122.42))
    XCTAssertNotNil(region(89.5, 180))
    XCTAssertNotNil(region(-89.5, -180))
    XCTAssertNotNil(region(0, 0, 180, 360))

    XCTAssertNil(region(90.5, 0))
    XCTAssertNil(region(-91, 0))
    XCTAssertNil(region(.nan, 0))
    XCTAssertNil(region(0, .infinity))
    XCTAssertNil(region(0, 0, 0, 1))
    XCTAssertNil(region(0, 0, 1, -1))
    XCTAssertNil(region(0, 0, .nan, 1))
  }

  /// Catches a region whose latitude edge crosses a pole, which MapKit refuses with an exception
  /// even though the center is on the globe. A region that reaches the pole exactly is fine.
  func testALatitudeEdgePastAPoleIsRefused() {
    XCTAssertNil(region(85, 0, 180, 1))
    XCTAssertNil(region(89, 0, 10, 1))
    XCTAssertNil(region(-89, 0, 10, 1))
    XCTAssertNil(region(90, 0, 1, 1))
    XCTAssertNotNil(region(80, 0, 20, 1))
    XCTAssertNotNil(region(-80, 0, 20, 1))
  }

  /// Catches a longitude past the antimeridian that is stored as it is, and a span past the globe
  /// that is not cut. The expected values are worked by hand.
  func testLongitudeWrapsAndSpansAreCut() throws {
    XCTAssertEqual(try XCTUnwrap(region(0, 190)).center.longitude, -170, accuracy: 1e-9)
    XCTAssertEqual(try XCTUnwrap(region(0, -190)).center.longitude, 170, accuracy: 1e-9)
    XCTAssertEqual(try XCTUnwrap(region(0, 540)).center.longitude, -180, accuracy: 1e-9)
    XCTAssertEqual(try XCTUnwrap(region(0, 45)).center.longitude, 45)

    let wide = try XCTUnwrap(region(0, 0, 400, 800))

    XCTAssertEqual(wide.span.latitudeDelta, 180)
    XCTAssertEqual(wide.span.longitudeDelta, 360)
  }

  /// Catches a stored region that restores out of range. Decoding goes through the same checks as
  /// making one.
  func testDecodingRefusesAnOutOfRangeRegion() throws {
    let span = #""span":{"latitudeDelta":1,"longitudeDelta":2}"#
    let good = #"{"center":{"latitude":10,"longitude":20},"# + span + "}"
    let bad = #"{"center":{"latitude":100,"longitude":20},"# + span + "}"

    XCTAssertEqual(
      try JSONDecoder().decode(GeoRegion.self, from: Data(good.utf8)), region(10, 20))
    XCTAssertThrowsError(try JSONDecoder().decode(GeoRegion.self, from: Data(bad.utf8)))
  }

  /// Catches a tolerance that is too loose to see a pan, or too tight to ignore the drift between
  /// a stored region and the one a map reports for it.
  func testIndistinguishableMeansWithinAThousandthOfTheSpan() throws {
    let base = try XCTUnwrap(region(10, 20, 1, 2))

    XCTAssertTrue(base.isIndistinguishable(from: try XCTUnwrap(region(10.0005, 20.001, 1, 2))))
    XCTAssertTrue(base.isIndistinguishable(from: try XCTUnwrap(region(10, 20, 1.0005, 2.001))))
    XCTAssertFalse(base.isIndistinguishable(from: try XCTUnwrap(region(10.01, 20, 1, 2))))
    XCTAssertFalse(base.isIndistinguishable(from: try XCTUnwrap(region(10, 20, 1.01, 2))))
  }
}

/// The stored names of the map styles.
final class MapStyleTests: XCTestCase {
  /// Catches a style renamed in the layout files users already have.
  func testTheStoredNamesAreTheContract() throws {
    XCTAssertEqual(MapStyle.allCases.map(\.rawValue), ["standard", "satellite", "hybrid"])

    for style in MapStyle.allCases {
      let data = try JSONEncoder().encode([style])

      XCTAssertEqual(String(decoding: data, as: UTF8.self), "[\"\(style.rawValue)\"]")
      XCTAssertEqual(try JSONDecoder().decode([MapStyle].self, from: data), [style])
    }
  }

  /// Catches an unknown name that is treated as damage, which would keep the whole pane from
  /// restoring. A name of the wrong type is still damage.
  func testAnUnknownNameIsTheStandardMap() throws {
    let decoded = try JSONDecoder().decode([MapStyle].self, from: Data(#"["terrain"]"#.utf8))

    XCTAssertEqual(decoded, [.standard])
    XCTAssertThrowsError(try JSONDecoder().decode([MapStyle].self, from: Data("[3]".utf8)))
  }
}
