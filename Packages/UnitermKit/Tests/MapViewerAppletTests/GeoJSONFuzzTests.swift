import Foundation
import GeoData
import TableTestSupport
import Theme
import XCTest

@testable import MapViewerApplet

/// A seeded mutation fuzzer for the GeoJSON reader as shipped. Each input is written to a file and
/// read through `GeoJSONFileReader`, which runs `MKGeoJSONDecoder` and then uniterm's own
/// extraction of pins, labels, accents, and glyphs.
///
/// `make test-package` runs it at a small count. `make fuzz` runs it under the address sanitizer
/// at a large one, through `UNITERM_FUZZ_ITERATIONS`. `UNITERM_FUZZ_SEED` repeats a run. A failure
/// names the seed and the iteration and keeps the input in the test's scratch folder.
///
/// It proves that no mutated input traps, reads out of bounds in uniterm's code, or breaks the
/// layer's own invariants. It cannot prove the pins are right. The reader tests prove that. The
/// address sanitizer sees MapKit's decoder and the JSON parser beneath it only through its
/// allocator and memory-function interceptors, because the system frameworks are not built with
/// instrumentation. A heap overflow inside their own code can go unseen, so a clean run is
/// weaker evidence than one over Swift code.
final class GeoJSONFuzzTests: XCTestCase {
  private var iterations: Int {
    ProcessInfo.processInfo.environment["UNITERM_FUZZ_ITERATIONS"].flatMap(Int.init) ?? 150
  }

  private var seed: UInt64 {
    ProcessInfo.processInfo.environment["UNITERM_FUZZ_SEED"].flatMap(UInt64.init) ?? 0x6E0
  }

  /// Catches an input that makes the reader trap, or a layer that breaks its own bounds: a pin
  /// past the point bound, a repeated ID, a coordinate off the globe, a label over its cap, an
  /// accent outside the set, or a failure that is not one of the pane's messages.
  func testMutatedFilesReadWithoutTrappingAndKeepTheLayerConsistent() throws {
    let scratch = try GeoScratch(self)
    var random = SplitMix64(seed: seed)
    let corpus = Self.corpus()
    var loaded = 0

    for iteration in 0..<iterations {
      var input = corpus[Int(random.next() % UInt64(corpus.count))]

      for _ in 0..<Int(random.next() % 4) {
        Self.mutate(&input, using: &random)
      }

      let file = scratch.url.appendingPathComponent("fuzz-\(iteration % 4).geojson")
      try Data(input).write(to: file)

      let context = "seed \(seed), iteration \(iteration), input kept at \(file.path)"
      let limits = GeoJSONLimits(
        maxBytes: random.next() % 8 == 0 ? 512 : 1 << 20,
        maxPoints: [3, 25, 10_000][Int(random.next() % 3)])

      switch GeoJSONFileReader.readBlocking(file, limits: limits) {
      case .success(let layer):
        loaded += 1
        Self.check(layer, limits: limits, context: context)

      case .failure(let error):
        switch error {
        case .invalid, .tooLarge:
          let text = error.errorDescription ?? ""

          XCTAssertFalse(text.isEmpty, context)
          XCTAssertFalse(text.lowercased().contains("corrupt"), context)

        case .access:
          XCTFail("a regular file failed to open: \(error), \(context)")
        }
      }

      if iteration % 4 == 3 {
        for slot in 0..<4 {
          try? FileManager.default.removeItem(
            at: scratch.url.appendingPathComponent("fuzz-\(slot).geojson"))
        }
      }
    }

    XCTAssertGreaterThan(loaded, iterations / 10, "too few inputs reached the extraction")
  }

  private static func check(_ layer: GeoFileLayer, limits: GeoJSONLimits, context: String) {
    XCTAssertLessThanOrEqual(layer.pins.count, limits.maxPoints, context)
    XCTAssertEqual(Set(layer.pins.map(\.id)).count, layer.pins.count, "repeated ID, \(context)")

    for pin in layer.pins {
      XCTAssertTrue(
        pin.coordinate.latitude.isFinite && pin.coordinate.longitude.isFinite
          && abs(pin.coordinate.latitude) <= 90 && abs(pin.coordinate.longitude) <= 180,
        "coordinate off the globe, \(context)")
      XCTAssertFalse(pin.label.isEmpty, context)
      XCTAssertLessThanOrEqual(pin.label.count, GeoFileLayerBuilder.maxLabelLength, context)

      if let accent = pin.accent { XCTAssertTrue(accent.isAccent, context) }

      if case .text(let text)? = pin.glyph { XCTAssertLessThanOrEqual(text.count, 2, context) }

      if case .symbol(let name)? = pin.glyph {
        XCTAssertLessThanOrEqual(name.utf8.count, PinGlyph.maxSymbolLength, context)
      }
    }

    for line in layer.notices(limit: limits.maxPoints) {
      XCTAssertFalse(line.isEmpty, context)
    }
  }

  // MARK: Corpus

  private static let interesting: [UInt8] =
    Array("{}[]\":,\\-+.eEuntrfalsd09/ ".utf8) + [
      0x0A, 0x00, 0xFF, 0xC3, 0xED, 0xA0, 0xEF, 0xBB, 0xBF,
    ]

  /// The seeds, written out in code since the repo holds no binary fixtures.
  private static func corpus() -> [[UInt8]] {
    let pin = GeoFixtures.point("Cafe", -122.4, 37.8)
    let styled = GeoFixtures.point(
      "S", 1, 2,
      extra:
        ##""marker-color":"#d20f39","marker-symbol":"7","uniterm:accent":"teal","uniterm:glyph":"star.fill""##
    )

    let texts = [
      GeoFixtures.collection([pin, GeoFixtures.multiPoint, GeoFixtures.line, GeoFixtures.polygon]),
      GeoFixtures.collection([styled, styled]),
      GeoFixtures.collection([]),
      #"{"type":"Point","coordinates":[10,20]}"#,
      #"{"type":"MultiPoint","coordinates":[[0,0],[1,1],[200,95],[1e999,0]]}"#,
      #"{"type":"GeometryCollection","geometries":[{"type":"Point","coordinates":[1,2]},{"type":"LineString","coordinates":[[0,0],[1,1]]}]}"#,
      #"{"type":"Feature","properties":null,"geometry":null}"#,
      #"{"type":"Feature","properties":{"name":["a"],"marker-color":5,"marker-symbol":{"a":1}},"geometry":{"type":"Point","coordinates":[1,2]}}"#,
      #"{"type":"Feature","id":"x","properties":{"name":"a\u0000b\ud800 \n\t"},"geometry":{"type":"Point","coordinates":[1,2,3,4]}}"#,
      #"{"type":"FeatureCollection","features":[{"type":"Feature","properties":{},"geometry":{"type":"Point","coordinates":[]}}]}"#,
      #"{"type":"Polygon","coordinates":[[[0,0],[1,0],[1,1]]]}"#,
      GeoFixtures.collection(
        (0..<200).map { GeoFixtures.point("P\($0)", Double($0 % 180), Double($0 % 90)) }),
      GeoFixtures.collection([
        GeoFixtures.point(String(repeating: "n", count: 5_000), 1, 2)
      ]),
      "[" + String(repeating: "[", count: 600) + String(repeating: "]", count: 600) + "]",
      String(repeating: "{\"type\":\"FeatureCollection\",\"features\":[", count: 120),
      #"{"type":"Point","coordinates":[1e308,-1e308]}"#, "{", "", "null", "[]",
    ]

    return texts.map { Array($0.utf8) } + [
      [0xEF, 0xBB, 0xBF] + Array(GeoFixtures.collection([pin]).utf8),
      [0xFF, 0xFE]
        + GeoFixtures.collection([pin]).utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] },
    ]
  }

  private static func mutate(_ input: inout [UInt8], using random: inout SplitMix64) {
    let size = input.count

    switch random.next() % 10 {
    case 8 where size > 0, 9 where size > 0:
      let digits = input.indices.filter { input[$0] >= 0x30 && input[$0] <= 0x39 }

      if let at = digits.isEmpty ? nil : digits[Int(random.next() % UInt64(digits.count))] {
        input[at] = UInt8(0x30 + random.next() % 10)
      }

    case 0 where size > 0:
      input[Int(random.next() % UInt64(size))] ^= UInt8(1 << (random.next() % 8))

    case 1 where size > 0:
      input[Int(random.next() % UInt64(size))] =
        interesting[Int(random.next() % UInt64(interesting.count))]

    case 2:
      let at = Int(random.next() % UInt64(size + 1))
      let bytes = (0..<(1 + Int(random.next() % 8))).map { _ in
        interesting[Int(random.next() % UInt64(interesting.count))]
      }
      input.insert(contentsOf: bytes, at: at)

    case 3 where size > 0:
      let start = Int(random.next() % UInt64(size))
      let end = min(size, start + 1 + Int(random.next() % 16))
      input.removeSubrange(start..<end)

    case 4 where size > 0:
      let start = Int(random.next() % UInt64(size))
      let end = min(size, start + 1 + Int(random.next() % 64))
      input.insert(contentsOf: Array(input[start..<end]), at: end)

    case 5 where size > 0:
      input.removeLast(Int(random.next() % UInt64(size)))

    case 6:
      input.insert(
        contentsOf: [[0xEF, 0xBB, 0xBF], [0xFF, 0xFE], [0xFE, 0xFF]][Int(random.next() % 3)], at: 0)

    default:
      input.append(contentsOf: Array("]}".utf8))
    }
  }
}
