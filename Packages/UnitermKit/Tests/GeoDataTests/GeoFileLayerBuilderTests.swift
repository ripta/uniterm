import Foundation
import ThemeCore
import XCTest

@testable import GeoData

/// The rules that turn GeoJSON objects into pins: IDs, labels, accents, glyphs, and the bounds.
final class GeoFileLayerBuilderTests: XCTestCase {
  private func properties(_ json: String) -> Data? { Data(json.utf8) }

  private func point(_ latitude: Double = 1, _ longitude: Double = 2) -> GeoCoordinate {
    GeoCoordinate(latitude: latitude, longitude: longitude)
  }

  private func build(_ features: [GeoFeatureInput], maxPoints: Int = 100) -> GeoFileLayer {
    var builder = GeoFileLayerBuilder(maxPoints: maxPoints)

    for feature in features { builder.add(feature) }

    return builder.layer
  }

  // MARK: IDs

  /// Catches IDs that repeat. The GeoJSON `id` is never used, so features with the same or no
  /// `id` still get distinct pins. Each ID is the ordinal and the point index, and a skipped
  /// feature still takes an ordinal, so the IDs name positions in the file.
  func testIDsAreOrdinalAndIndexAndNeverRepeat() {
    let layer = build([
      GeoFeatureInput(propertiesJSON: properties(#"{"id":"same"}"#), points: [point()]),
      GeoFeatureInput(points: [], skippedShapes: 1),
      GeoFeatureInput(
        propertiesJSON: properties(#"{"id":"same"}"#),
        points: [point(3, 4), point(3, 4), point(5, 6)]),
    ])

    XCTAssertEqual(layer.pins.map(\.id), ["0:0", "2:0", "2:1", "2:2"])
    XCTAssertEqual(Set(layer.pins.map(\.id)).count, layer.pins.count)
  }

  // MARK: Labels

  /// Catches a label order that changes. The first non-blank string among `name`, `title`, and
  /// `label` wins, a number is not a label, and control characters become spaces.
  func testLabelRule() {
    let cases: [(String, String)] = [
      (#"{"name":"A","title":"B","label":"C"}"#, "A"),
      (#"{"name":"  ","title":"B","label":"C"}"#, "B"),
      (#"{"name":5,"label":"C"}"#, "C"),
      (#"{"name":"a\nb\tc"}"#, "a b c"),
      (#"{"description":"not a label"}"#, "1.00000, 2.00000"),
      ("null", "1.00000, 2.00000"),
      ("[1,2]", "1.00000, 2.00000"),
    ]

    for (json, expected) in cases {
      let layer = build([GeoFeatureInput(propertiesJSON: properties(json), points: [point()])])

      XCTAssertEqual(layer.pins.first?.label, expected, json)
    }

    let long = String(repeating: "x", count: 1000)
    let layer = build([
      GeoFeatureInput(propertiesJSON: properties(#"{"name":"\#(long)"}"#), points: [point()])
    ])

    XCTAssertEqual(layer.pins.first?.label.count, GeoFileLayerBuilder.maxLabelLength)
  }

  /// Catches text that hides or reorders the label. Bidirectional overrides and isolates, a byte
  /// order mark, and line and paragraph separators become spaces, so none reaches the callout or
  /// the accessibility label. The joiners that emoji sequences use stay.
  func testHiddenFormatCharactersNeverReachALabel() {
    let hidden = [
      "a\u{202E}b", "a\u{2066}b", "a\u{200B}b", "a\u{FEFF}b", "a\u{2028}b", "a\u{2029}b",
    ]

    for text in hidden {
      let json =
        #"{"name":"\#(text.unicodeScalars.map { String(format: "\\u%04X", $0.value) }.joined())"}"#
      let layer = build([GeoFeatureInput(propertiesJSON: properties(json), points: [point()])])
      let label = layer.pins.first?.label ?? ""

      XCTAssertEqual(label, "a b", json)
    }

    let family = "\u{1F468}\u{200D}\u{1F469}"
    let json = #"{"name":"\#(family)"}"#
    let kept = build([GeoFeatureInput(propertiesJSON: properties(json), points: [point()])])

    XCTAssertEqual(kept.pins.first?.label, family)
    XCTAssertNil(PinGlyph("A\u{202E}"))
    XCTAssertNotNil(PinGlyph(family))
  }

  /// Catches work and counts that go wrong once the layer is full. The properties of later
  /// features are not read, yet their points still add to the truncation, the skipped shapes, and
  /// the points off the globe. This pins the result of the early exit. It cannot show that the
  /// properties went unread, since the output is the same either way.
  func testAFullLayerKeepsCountingWhatItLeavesOut() {
    var builder = GeoFileLayerBuilder(maxPoints: 1)

    builder.add(GeoFeatureInput(points: [point(1, 1)]))
    XCTAssertTrue(builder.isFull)
    XCTAssertFalse(builder.layer.truncated)

    builder.add(
      GeoFeatureInput(
        propertiesJSON: properties(#"{"marker-color":"nope"}"#), points: [point(91, 0)],
        skippedShapes: 1))
    XCTAssertFalse(builder.layer.truncated)

    builder.add(
      GeoFeatureInput(
        propertiesJSON: properties(#"{"marker-color":"nope"}"#), points: [point(2, 2)]))

    XCTAssertEqual(builder.layer.pins.count, 1)
    XCTAssertTrue(builder.layer.truncated)
    XCTAssertEqual(builder.layer.skippedShapes, 1)
    XCTAssertEqual(builder.layer.invalidCoordinates, 1)
    XCTAssertEqual(builder.layer.unusableStyleValues, 0)
  }

  // MARK: Accents and glyphs

  private func style(_ json: String) -> (GeoPin, GeoFileLayer) {
    let layer = build([GeoFeatureInput(propertiesJSON: properties(json), points: [point()])])

    return (layer.pins[0], layer)
  }

  /// Catches an accent rule that stores a color or reads the wrong key. A `uniterm:accent` token
  /// wins over `marker-color`, a hex `marker-color` becomes the nearest accent token, and with
  /// neither the accent is nil so the layer default applies.
  func testAccentRule() {
    XCTAssertEqual(style(#"{"uniterm:accent":"teal"}"#).0.accent, .teal)
    XCTAssertEqual(style(##"{"marker-color":"#d20f39"}"##).0.accent, .red)
    XCTAssertEqual(style(##"{"uniterm:accent":"teal","marker-color":"#d20f39"}"##).0.accent, .teal)
    XCTAssertNil(style(#"{"name":"x"}"#).0.accent)

    let (_, clean) = style(##"{"uniterm:accent":"teal","marker-color":"#d20f39"}"##)

    XCTAssertEqual(clean.unusableStyleValues, 0)
  }

  /// Catches a glyph rule that reads the wrong key or draws a Maki icon. `uniterm:glyph` wins, a
  /// one- or two-character `marker-symbol` is the glyph, and a longer one is a Maki name that is
  /// ignored without a count.
  func testGlyphRule() {
    XCTAssertEqual(style(#"{"uniterm:glyph":"star.fill"}"#).0.glyph, .symbol("star.fill"))
    XCTAssertEqual(style(#"{"marker-symbol":"7"}"#).0.glyph, .text("7"))
    XCTAssertEqual(style(#"{"marker-symbol":"12"}"#).0.glyph, .text("12"))
    XCTAssertEqual(style(#"{"uniterm:glyph":"Q","marker-symbol":"7"}"#).0.glyph, .text("Q"))

    let (maki, layer) = style(#"{"marker-symbol":"restaurant"}"#)

    XCTAssertNil(maki.glyph)
    XCTAssertEqual(layer.unusableStyleValues, 0)
  }

  /// Catches an unusable value that is silently dropped, or counted twice for one pin. Each
  /// unusable value falls back and adds one to the count.
  func testUnusableStyleValuesFallBackAndAreCounted() {
    let (pin, layer) = style(
      #"{"uniterm:accent":"chartreuse","marker-color":"red","uniterm:glyph":"A B C D","marker-symbol":3}"#
    )

    XCTAssertNil(pin.accent)
    XCTAssertNil(pin.glyph)
    XCTAssertEqual(layer.unusableStyleValues, 4)
    XCTAssertTrue(layer.notices(limit: 100).contains { $0.hasPrefix("4 pin style values") })

    let (fallback, _) = style(##"{"uniterm:accent":"base","marker-color":"#0000ff"}"##)

    XCTAssertEqual(fallback.accent, .blue)
  }

  // MARK: Bounds

  /// Catches a point bound that is off by one or silent. A file past the bound loads its first
  /// points and says so, and a file at the bound does not.
  func testThePointBoundKeepsTheFirstPointsAndSaysSo() {
    let features = [
      GeoFeatureInput(points: [point(1, 1), point(2, 2)]),
      GeoFeatureInput(points: [point(3, 3), point(4, 4)]),
    ]

    let cut = build(features, maxPoints: 3)

    XCTAssertEqual(cut.pins.map(\.id), ["0:0", "0:1", "1:0"])
    XCTAssertTrue(cut.truncated)
    XCTAssertEqual(
      cut.notices(limit: 3).first, "The file has more than 3 points. Showing the first 3.")

    let exact = build(features, maxPoints: 4)

    XCTAssertEqual(exact.pins.count, 4)
    XCTAssertFalse(exact.truncated)
  }

  /// Catches a coordinate off the globe that reaches MapKit, and a skipped shape that goes
  /// uncounted.
  func testBadCoordinatesAndShapesAreSkippedAndCounted() {
    let layer = build([
      GeoFeatureInput(
        points: [point(91, 0), point(0, 181), point(.nan, 0), point(.infinity, 0), point(0, 0)]),
      GeoFeatureInput(points: [], skippedShapes: 2),
    ])

    XCTAssertEqual(layer.pins.map(\.id), ["0:4"])
    XCTAssertEqual(layer.invalidCoordinates, 4)
    XCTAssertEqual(layer.skippedShapes, 2)
    XCTAssertEqual(
      layer.notices(limit: 100),
      [
        "Skipped 2 shapes that are not points. The map shows points only.",
        "Skipped 4 points with coordinates off the globe.",
      ])
  }
}
