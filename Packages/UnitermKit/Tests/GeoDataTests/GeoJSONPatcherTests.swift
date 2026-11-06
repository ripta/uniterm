import Foundation
import ThemeCore
import XCTest

@testable import GeoData

/// The patcher's contract: an edit changes the values it names and no other byte.
///
/// Expected documents are written out in full, so a change anywhere else in the file fails the
/// comparison. The fixtures carry what the map cannot show, such as a LineString, a foreign member,
/// unknown properties, odd spacing, and escapes, to prove those survive.
final class GeoJSONPatcherTests: XCTestCase {
  private func pin(
    _ id: String, _ longitude: Double, _ latitude: Double, _ label: String,
    accent: ThemeToken? = nil, glyph: PinGlyph? = nil
  ) -> GeoPin {
    GeoPin(
      id: id, coordinate: GeoCoordinate(latitude: latitude, longitude: longitude), label: label,
      accent: accent, glyph: glyph)
  }

  private func apply(_ edit: PinEdit, to text: String) throws -> String {
    String(decoding: try GeoJSONPatcher.apply(edit, to: Data(text.utf8)), as: UTF8.self)
  }

  private let mixed = """
    {
      "type": "FeatureCollection",
      "x-source": {"tool": "hand", "note": "keep\\u00e9 me"},
      "features": [
        {"type": "Feature", "properties": {"name": "Caf\\u00e9 \\"A\\"", "rank": 1},
         "geometry": {"type": "Point", "coordinates": [2.35,48.85,35]}},
        {"type": "Feature", "properties": {"kind": "route"},
         "geometry": {"type": "LineString", "coordinates": [[0, 0], [1, 1]]}},
        {"type": "Feature", "properties": null,
         "geometry": {"type": "MultiPoint", "coordinates": [[10, 20], [11, 21], [12, 22]]}}
      ]
    }

    """

  /// Catches a rename that rewrites more than the label. Only the `name` value changes, and its
  /// escapes are written as JSON.
  func testARenameReplacesOnlyTheLabelValue() throws {
    let old = pin("0:0", 2.35, 48.85, "Caf\u{E9} \"A\"")
    let new = pin("0:0", 2.35, 48.85, "Caf\u{E9} / \"B\"")

    let result = try apply(.update(old: old, new: new), to: mixed)

    XCTAssertEqual(
      result,
      mixed.replacingOccurrences(
        of: "\"name\": \"Caf\\u00e9 \\\"A\\\"\"", with: "\"name\": \"Caf\u{E9} / \\\"B\\\"\""))
  }

  /// Catches a move that drops the altitude or the file's own spacing, or touches another value.
  func testAMoveKeepsTheAltitudeAndTheSpacing() throws {
    let old = pin("0:0", 2.35, 48.85, "x")
    let new = pin("0:0", 2.5, 48.75, "x")

    let result = try apply(.update(old: old, new: new), to: mixed)

    XCTAssertEqual(
      result, mixed.replacingOccurrences(of: "[2.35,48.85,35]", with: "[2.5,48.75,35]"))
  }

  /// Catches a move of one MultiPoint member that rewrites its neighbors.
  func testMovingAMultiPointMemberRewritesThatMemberOnly() throws {
    let result = try apply(
      .update(old: pin("2:1", 11, 21, "a"), new: pin("2:1", 11.5, 21.5, "a")), to: mixed)

    XCTAssertEqual(
      result,
      mixed.replacingOccurrences(
        of: "[[10, 20], [11, 21], [12, 22]]", with: "[[10, 20], [11.5, 21.5], [12, 22]]"))
  }

  /// Catches an added pin that breaks the collection's layout or lands outside it. The new
  /// feature follows the last one, with the separator the file already uses.
  func testAnAddFollowsTheLastFeatureWithTheFilesSeparator() throws {
    let result = try apply(.add(pin("", -118.25, 34.05, "LA", accent: .blue)), to: mixed)

    XCTAssertEqual(
      result,
      mixed.replacingOccurrences(
        of: "[[10, 20], [11, 21], [12, 22]]}}\n",
        with: """
          [[10, 20], [11, 21], [12, 22]]}},
              {"type": "Feature", "properties": {"name": "LA", "uniterm:accent": "blue"}, \
          "geometry": {"type": "Point", "coordinates": [-118.25, 34.05]}}

          """))

    let object = try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any]
    XCTAssertEqual((object?["features"] as? [Any])?.count, 4)
  }

  /// Catches a new file that is not valid GeoJSON, or a second add that breaks the first.
  func testAddsBuildANewFileFromTheEmptyDocument() throws {
    var data = GeoJSONPatcher.emptyDocument
    data = try GeoJSONPatcher.apply(.add(pin("", 1, 2, "One")), to: data)
    data = try GeoJSONPatcher.apply(.add(pin("", 3, 4, "Two")), to: data)

    XCTAssertEqual(
      String(decoding: data, as: UTF8.self),
      """
      {
        "type": "FeatureCollection",
        "features": [
          {"type": "Feature", "properties": {"name": "One"}, "geometry": {"type": "Point", "coordinates": [1.0, 2.0]}},
          {"type": "Feature", "properties": {"name": "Two"}, "geometry": {"type": "Point", "coordinates": [3.0, 4.0]}}
        ]
      }

      """)
  }

  /// Catches a removal that leaves a stray comma, which would make the file unreadable, in the
  /// middle, at the end, and for the only feature.
  func testRemovalsLeaveValidJSONWhereverTheFeatureSits() throws {
    for (id, expected) in [("0:0", 2), ("2:0", 3)] {
      let edited = try apply(.remove(pin(id, 0, 0, "")), to: mixed)
      let object = try JSONSerialization.jsonObject(with: Data(edited.utf8)) as? [String: Any]

      XCTAssertEqual((object?["features"] as? [Any])?.count, expected, id)
    }

    let multi = try apply(.remove(pin("2:1", 11, 21, "")), to: mixed)
    XCTAssertTrue(multi.contains("[[10, 20], [12, 22]]"), multi)

    let one =
      #"{"type":"FeatureCollection","features":[{"type":"Feature","properties":{},"geometry":{"type":"Point","coordinates":[1,2]}}]}"#
    XCTAssertEqual(
      try apply(.remove(pin("0:0", 1, 2, "")), to: one),
      #"{"type":"FeatureCollection","features":[]}"#)
  }

  /// Catches restyling one MultiPoint member that restyles all of them. That member moves out to
  /// its own Point feature, and the others keep their shared properties.
  func testRestylingAMultiPointMemberMovesItOut() throws {
    let result = try apply(
      .update(
        old: pin("2:2", 12, 22, "12.00000, 22.00000"), new: pin("2:2", 12, 22, "Here", accent: .red)
      ),
      to: mixed)

    XCTAssertTrue(result.contains("[[10, 20], [11, 21]]"), result)
    XCTAssertTrue(
      result.contains(
        #"{"type": "Feature", "properties": {"name": "Here", "uniterm:accent": "red"}, "geometry": {"type": "Point", "coordinates": [12.0, 22.0]}}"#
      ), result)
  }

  /// Catches the accent and glyph keys being written where the reader does not look, or a
  /// default choice that leaves the key behind. A removal keeps the members around it.
  func testStyleKeysAreSetAndRemoved() throws {
    let text =
      #"{"type": "FeatureCollection", "features": [{"type": "Feature", "properties": {"name": "A", "uniterm:accent": "teal", "marker-symbol": "x"}, "geometry": {"type": "Point", "coordinates": [1, 2]}}]}"#
    let old = pin("0:0", 1, 2, "A", accent: .teal)

    let restyled = try apply(
      .update(old: old, new: pin("0:0", 1, 2, "A", accent: .mauve)), to: text)
    XCTAssertEqual(restyled, text.replacingOccurrences(of: "\"teal\"", with: "\"mauve\""))

    let plain = try apply(
      .update(old: old, new: pin("0:0", 1, 2, "A", glyph: PinGlyph("★"))), to: text)
    XCTAssertEqual(
      plain,
      text.replacingOccurrences(
        of: #""uniterm:accent": "teal", "marker-symbol": "x""#,
        with: #""marker-symbol": "x", "uniterm:glyph": "★""#))
  }

  /// Catches a blank label written as an empty name. Clearing the label removes it, so the pin
  /// shows its coordinate.
  func testABlankLabelRemovesTheName() throws {
    let text =
      #"{"type": "FeatureCollection", "features": [{"type": "Feature", "properties": {"name": "A", "rank": 2}, "geometry": {"type": "Point", "coordinates": [1, 2]}}]}"#

    let result = try apply(
      .update(old: pin("0:0", 1, 2, "A"), new: pin("0:0", 1, 2, "  ")), to: text)

    XCTAssertEqual(result, text.replacingOccurrences(of: #""name": "A", "#, with: ""))
  }

  /// Catches a feature with null or missing properties that cannot be labeled.
  func testAFeatureWithoutPropertiesGainsThem() throws {
    let null =
      #"{"type":"FeatureCollection","features":[{"type":"Feature","properties":null,"geometry":{"type":"Point","coordinates":[1,2]}}]}"#
    let missing =
      #"{"type":"FeatureCollection","features":[{"type":"Feature","geometry":{"type":"Point","coordinates":[1,2]}}]}"#
    let old = pin("0:0", 1, 2, "2.00000, 1.00000")
    let new = pin("0:0", 1, 2, "Named")

    XCTAssertEqual(
      try apply(.update(old: old, new: new), to: null),
      null.replacingOccurrences(of: "null", with: #"{"name": "Named"}"#))
    XCTAssertEqual(
      try apply(.update(old: old, new: new), to: missing),
      missing.replacingOccurrences(
        of: #"{"type":"Feature","#, with: #"{"properties": {"name": "Named"}, "type":"Feature","#))
  }

  /// Catches a single Feature or a bare geometry that cannot gain a second pin. Each is wrapped in
  /// a collection with its own bytes inside unchanged.
  func testASingleFeatureOrGeometryIsWrapped() throws {
    let feature =
      #"{"type":"Feature","properties":{"name":"A"},"geometry":{"type":"Point","coordinates":[1,2]}}"#
    let wrapped = try apply(.add(pin("", 3, 4, "B")), to: feature + "\n")

    XCTAssertTrue(
      wrapped.hasPrefix(#"{"type": "FeatureCollection", "features": ["# + feature + ","))
    XCTAssertTrue(wrapped.hasSuffix("]}\n"))

    let point = #"{"type":"Point","coordinates":[1,2]}"#
    let moved = try apply(
      .update(old: pin("0:0", 1, 2, "x"), new: pin("0:0", 5, 6, "x")), to: point)
    XCTAssertEqual(
      moved,
      #"{"type": "FeatureCollection", "features": [{"type": "Feature", "properties": null, "geometry": {"type":"Point","coordinates":[5.0,6.0]}}]}"#
    )
  }

  /// Catches an edit that rewrites shapes the map does not show, an unknown pin, and a file that
  /// is not JSON. Each refuses with its own error and writes nothing.
  func testEditsThatCannotBeMadeAreRefused() {
    let collection =
      #"{"type":"FeatureCollection","features":[{"type":"Feature","properties":{},"geometry":{"type":"GeometryCollection","geometries":[{"type":"Point","coordinates":[1,2]}]}}]}"#

    XCTAssertThrowsError(try apply(.remove(pin("0:0", 1, 2, "")), to: collection)) {
      XCTAssertEqual($0 as? PinEditError, .notEditable("0:0"))
    }

    XCTAssertThrowsError(try apply(.remove(pin("9:0", 1, 2, "")), to: mixed)) {
      XCTAssertEqual($0 as? PinEditError, .notFound("9:0"))
    }

    XCTAssertThrowsError(
      try apply(.add(pin("", 1, 2, "")), to: #"{"type": "FeatureCollection", "features": [}"#)
    ) {
      guard case .unreadable = $0 as? PinEditError else { return XCTFail("\($0)") }
    }

    let deep = String(repeating: "[", count: 5000) + String(repeating: "]", count: 5000)
    XCTAssertThrowsError(try apply(.add(pin("", 1, 2, "")), to: deep))
  }
}
