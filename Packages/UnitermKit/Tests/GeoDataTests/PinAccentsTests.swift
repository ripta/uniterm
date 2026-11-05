import ThemeCore
import XCTest

@testable import GeoData

final class PinAccentsTests: XCTestCase {
  /// Catches an order that lists an accent twice or leaves one out. The order is a permutation of
  /// the accent set, so every layer up to 14 gets a different color.
  func testTheLayerOrderIsEveryAccentOnce() {
    XCTAssertEqual(PinAccents.layerOrder.count, 14)
    XCTAssertEqual(Set(PinAccents.layerOrder), Set(ThemeToken.accents))
    XCTAssertEqual(PinAccents.layerDefault(at: 0), .blue)
    XCTAssertEqual(PinAccents.layerDefault(at: 14), .blue)
    XCTAssertEqual(PinAccents.layerDefault(at: 15), PinAccents.layerOrder[1])
  }

  /// Catches an order whose neighbors look alike. The rosewater and flamingo accents are never
  /// adjacent, in either direction or around the wrap. Every neighbor pair is at least 0.12 apart
  /// in OKLab in both flavors, where the closest pair in the shipped order is 0.124 in Mocha.
  func testNeighborsInTheLayerOrderAreDistinct() {
    let order = PinAccents.layerOrder

    for index in order.indices {
      let first = order[index]
      let second = order[(index + 1) % order.count]

      XCTAssertFalse(
        [first, second] == [.rosewater, .flamingo] || [first, second] == [.flamingo, .rosewater],
        "\(first) next to \(second)")

      for palette in [ThemePalette.latte, ThemePalette.mocha] {
        let distance = palette[first].oklabDistance(to: palette[second])

        XCTAssertGreaterThanOrEqual(
          distance, 0.12, "\(first) and \(second) in \(palette.flavor)")
      }
    }
  }

  /// Catches a stored name that passes for an accent when it is not one.
  func testOnlyAccentNamesValidate() {
    XCTAssertEqual(PinAccents.validated("sapphire"), .sapphire)
    XCTAssertNil(PinAccents.validated("base"))
    XCTAssertNil(PinAccents.validated("#ff0000"))
    XCTAssertNil(PinAccents.validated(nil))
  }

  /// Catches a hex reader that takes a bad color or drops a good form. The short form doubles each
  /// digit, the hash is optional, and case does not matter.
  func testHexForms() {
    XCTAssertEqual(PinAccents.parseHex("#d20f39")?.hexString, "#d20f39")
    XCTAssertEqual(PinAccents.parseHex("D20F39")?.hexString, "#d20f39")
    XCTAssertEqual(PinAccents.parseHex("#f00")?.hexString, "#ff0000")
    XCTAssertNil(PinAccents.parseHex("#ff00"))
    XCTAssertNil(PinAccents.parseHex("#gggggg"))
    XCTAssertNil(PinAccents.parseHex("red"))
    XCTAssertNil(PinAccents.parseHex(""))
    XCTAssertNil(PinAccents.parseHex("#12345678"))
  }

  /// Catches a mapping that is not the nearest accent in OKLab against Latte. Each accent's own
  /// Latte color maps to itself. The expected neighbors are worked out from the distances, not the
  /// code: a pure red is 0.070 from maroon and 0.096 from red, so it maps to maroon, a pure blue
  /// to blue, and a pure yellow to yellow.
  func testNearestAccentAgainstLatte() {
    for token in ThemeToken.accents {
      XCTAssertEqual(PinAccents.nearest(to: ThemePalette.latte[token]), token)
    }

    XCTAssertEqual(PinAccents.nearest(to: ThemeColor(hex: 0xFF0000)), .maroon)
    XCTAssertEqual(PinAccents.nearest(to: ThemeColor(hex: 0x0000FF)), .blue)
    XCTAssertEqual(PinAccents.nearest(to: ThemeColor(hex: 0xFFFF00)), .yellow)
  }
}

final class PinGlyphTests: XCTestCase {
  /// Catches a glyph rule that takes a bad value. One or two characters are text, a lowercase
  /// dotted name is a symbol, and anything else is refused.
  func testGlyphForms() {
    XCTAssertEqual(PinGlyph("A"), .text("A"))
    XCTAssertEqual(PinGlyph(" 12 "), .text("12"))
    XCTAssertEqual(PinGlyph("\u{1F355}"), .text("\u{1F355}"))
    XCTAssertEqual(PinGlyph("star.fill"), .symbol("star.fill"))
    XCTAssertEqual(PinGlyph("tram"), .symbol("tram"))
    XCTAssertNil(PinGlyph(""))
    XCTAssertNil(PinGlyph("   "))
    XCTAssertNil(PinGlyph("Star.fill"))
    XCTAssertNil(PinGlyph("a b c"))
    XCTAssertNil(PinGlyph("star..fill"))
    XCTAssertNil(PinGlyph("\u{7}"))
    XCTAssertNil(PinGlyph(String(repeating: "a", count: 65)))
  }
}

final class GeoRegionFittingTests: XCTestCase {
  /// Catches a fit that misses a coordinate or passes a pole. Every coordinate lies inside the
  /// fitted box, and a single coordinate gets the smallest span.
  func testFittingCoversEveryCoordinateWithinTheGlobe() throws {
    let points = [
      GeoCoordinate(latitude: 10, longitude: 20), GeoCoordinate(latitude: 14, longitude: 30),
    ]

    let region = try XCTUnwrap(GeoRegion.fitting(points))

    for point in points {
      XCTAssertLessThanOrEqual(
        abs(point.latitude - region.center.latitude), region.span.latitudeDelta / 2)
      XCTAssertLessThanOrEqual(
        abs(point.longitude - region.center.longitude), region.span.longitudeDelta / 2)
    }

    let single = try XCTUnwrap(GeoRegion.fitting([GeoCoordinate(latitude: 89.99, longitude: 0)]))

    XCTAssertEqual(single.span.latitudeDelta, GeoRegion.minimumFittedSpan)
    XCTAssertLessThanOrEqual(single.center.latitude + single.span.latitudeDelta / 2, 90)
    XCTAssertNil(GeoRegion.fitting([]))
  }
}
