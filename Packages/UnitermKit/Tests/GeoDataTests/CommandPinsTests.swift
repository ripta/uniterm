import ThemeCore
import XCTest

@testable import GeoData

final class CommandPinsTests: XCTestCase {
  private func pin(_ id: String, label: String? = nil) throws -> GeoPin {
    try CommandPins.pin(
      id: id, latitude: 1, longitude: 2, label: label, accent: nil, glyph: nil)
  }

  // MARK: Rules

  /// Catches a text cap that counts graphemes. A family emoji is one grapheme and 25 bytes, so
  /// five of them are five graphemes and 125 bytes. A grapheme count would let a label of any
  /// size through.
  func testTextCapsCountBytesNotGraphemes() throws {
    let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"

    XCTAssertEqual(family.count, 1)
    XCTAssertEqual(family.utf8.count, 25)
    XCTAssertNoThrow(try pin("a", label: String(repeating: family, count: 5)))
    XCTAssertThrowsError(try pin("a", label: String(repeating: family, count: 6)))
    XCTAssertThrowsError(try pin(String(repeating: "x", count: 65)))
    XCTAssertNoThrow(try pin(String(repeating: "x", count: 64)))
    XCTAssertThrowsError(try CommandPins.layerName(String(repeating: "\u{E9}", count: 33)))
    XCTAssertNoThrow(try CommandPins.layerName(String(repeating: "\u{E9}", count: 32)))
  }

  /// Catches a label that carries a bidirectional override or a control into the callout, an empty
  /// ID, and an unknown accent. A label with no visible text takes the coordinate.
  func testLabelsAreCleanedAndBadValuesRefused() throws {
    let cleaned = try pin("a", label: "a\u{202E}b\u{7}c")

    XCTAssertEqual(cleaned.label, "a b c")
    XCTAssertEqual(try pin("a", label: " \u{7} ").label, "1.00000, 2.00000")
    XCTAssertEqual(try pin("a").label, GeoFileLayerBuilder.coordinateText(cleaned.coordinate))
    XCTAssertThrowsError(try pin(""))
    XCTAssertThrowsError(try pin("a\u{202E}"))
    XCTAssertThrowsError(try CommandPins.layerName(""))

    XCTAssertThrowsError(
      try CommandPins.pin(
        id: "a", latitude: 1, longitude: 2, label: nil, accent: "chartreuse", glyph: nil))
    XCTAssertThrowsError(
      try CommandPins.pin(
        id: "a", latitude: 91, longitude: 2, label: nil, accent: nil, glyph: nil))
    XCTAssertThrowsError(
      try CommandPins.pin(
        id: "a", latitude: 1, longitude: .nan, label: nil, accent: nil, glyph: nil))
    XCTAssertThrowsError(
      try CommandPins.pin(
        id: "a", latitude: 1, longitude: 2, label: nil, accent: nil, glyph: "no way"))
    XCTAssertEqual(try CommandPins.layerName(nil), "default")
  }

  // MARK: Layers

  /// Catches a pin that is added twice instead of replaced whole, and a replacement that keeps
  /// the earlier accent or glyph.
  func testAddReplacesAPinWholeInPlace() throws {
    var layers = CommandLayers()
    let first = try CommandPins.pin(
      id: "a", latitude: 1, longitude: 2, label: "one", accent: "red", glyph: "x")

    try layers.add(first, to: "default")
    try layers.add(try pin("b"), to: "default")
    try layers.add(try pin("a", label: "two"), to: "default")

    let held = try XCTUnwrap(layers.layer(named: "default")).pins

    XCTAssertEqual(held.map(\.id), ["a", "b"])
    XCTAssertEqual(held[0].label, "two")
    XCTAssertNil(held[0].accent)
    XCTAssertNil(held[0].glyph)
  }

  /// Catches a layer that takes a new accent after a clear, and a layer that shares the file
  /// layer's first accent. Layers take the order from index 1 on, and keep it.
  func testALayerKeepsItsAccentAfterAClear() throws {
    var layers = CommandLayers()

    try layers.add(try pin("a"), to: "one")
    try layers.add(try pin("a"), to: "two")

    let accents = layers.layers.map(\.accent)

    XCTAssertEqual(accents, [PinAccents.layerDefault(at: 1), PinAccents.layerDefault(at: 2)])
    XCTAssertNotEqual(accents[0], PinAccents.layerDefault(at: 0))

    _ = layers.clear(layer: "one")
    try layers.add(try pin("z"), to: "one")

    XCTAssertEqual(layers.layer(named: "one")?.accent, accents[0])
  }

  /// Catches a set-layer that leaves part of the old layer, a repeated ID that is kept, and a cap
  /// that is counted before the replaced pins go. A layer at the pane's cap can be replaced by
  /// one of the same size.
  func testReplaceIsWholeAndTheCapCountsAfterTheOldPinsGo() throws {
    var layers = CommandLayers()
    let big = try (0..<CommandPinLimits.maxPinsPerLayer).map { try pin("p\($0)") }

    try layers.replace(layer: "a", with: big)
    try layers.replace(layer: "b", with: big)
    try layers.replace(layer: "c", with: big)
    try layers.replace(layer: "d", with: Array(big.prefix(600)))

    let before = layers

    XCTAssertThrowsError(try layers.replace(layer: "e", with: big)) {
      XCTAssertEqual(($0 as? CommandPinError)?.kind, .capReached)
    }
    XCTAssertEqual(layers, before, "a refused replace changed the layers")

    XCTAssertNoThrow(try layers.replace(layer: "a", with: big))
    XCTAssertNoThrow(try layers.replace(layer: "a", with: [try pin("only")]))
    XCTAssertEqual(layers.layer(named: "a")?.pins.map(\.id), ["only"])

    XCTAssertThrowsError(try layers.replace(layer: "a", with: [try pin("x"), try pin("x")])) {
      XCTAssertEqual(($0 as? CommandPinError)?.kind, .badArgument)
    }
    XCTAssertEqual(layers.layer(named: "a")?.pins.map(\.id), ["only"])
  }

  /// Catches a layer cap that forgets empty layers, and a refused layer that is made anyway.
  func testEmptyLayersCountAgainstTheLayerCap() throws {
    var layers = CommandLayers()

    for index in 0..<CommandPinLimits.maxLayersPerPane {
      try layers.replace(layer: "l\(index)", with: [])
    }

    let before = layers

    XCTAssertThrowsError(try layers.replace(layer: "extra", with: []))
    XCTAssertThrowsError(try layers.add(try pin("a"), to: "extra"))
    XCTAssertEqual(layers, before)
    XCTAssertNoThrow(try layers.add(try pin("a"), to: "l0"))
  }

  /// Catches a per-layer cap that an add steps past one pin at a time.
  func testAddsStopAtThePerLayerCap() throws {
    var layers = CommandLayers()

    for index in 0..<CommandPinLimits.maxPinsPerLayer {
      try layers.add(try pin("p\(index)"), to: "a")
    }

    XCTAssertThrowsError(try layers.add(try pin("one-more"), to: "a"))
    XCTAssertNoThrow(try layers.add(try pin("p0", label: "same id"), to: "a"))
    XCTAssertEqual(layers.layer(named: "a")?.pins.count, CommandPinLimits.maxPinsPerLayer)
  }

  /// Catches a layer counted twice for a rerun, and one counted while it holds no pins.
  func testALayerCountsOnceWhenItFirstHoldsPins() throws {
    var layers = CommandLayers()

    XCTAssertFalse(try layers.replace(layer: "a", with: []).becameCounted)
    XCTAssertTrue(try layers.add(try pin("x"), to: "a").becameCounted)
    XCTAssertFalse(try layers.add(try pin("y"), to: "a").becameCounted)

    _ = layers.clear(layer: "a")

    XCTAssertFalse(try layers.add(try pin("x"), to: "a").becameCounted)
    XCTAssertEqual(layers.countedNames, ["a"])
  }

  // MARK: Sizing

  /// Catches a cap that does not follow the smallest bound. The frame binds here, and a larger
  /// frame lifts the cap until the value bound binds.
  func testThePerLayerCapIsTheSmallestBound() {
    let bytes = CommandFrameSizing.pinsFitting(
      frameBytes: CommandFrameSizing.frameBytes, maxValues: .max / 2,
      retainedBytes: CommandFrameSizing.retainedBytes)
    let values = CommandFrameSizing.pinsFitting(
      frameBytes: .max / 2, maxValues: 2_064, retainedBytes: .max / 2)
    let retained = CommandFrameSizing.pinsFitting(
      frameBytes: .max / 2, maxValues: .max / 2, retainedBytes: 100_000)

    XCTAssertEqual(CommandPinLimits.maxPinsPerLayer, bytes)
    XCTAssertEqual(values, 100)
    XCTAssertEqual(
      retained, (100_000 - CommandFrameSizing.envelopeBytes) / CommandFrameSizing.worstPinBytes)
    XCTAssertLessThanOrEqual(CommandPinLimits.maxPinsPerLayer, CommandPinLimits.maxPinsPerPane)
  }

  // MARK: Snapshot

  /// Catches a snapshot that loses a layer, an accent, a pin's glyph, or the counted names, and
  /// one that restores a layer unmarked.
  func testASnapshotRoundTripsAndMarksEarlierRuns() throws {
    var layers = CommandLayers()

    try layers.add(
      try CommandPins.pin(
        id: "a", latitude: 1, longitude: 2, label: "A", accent: "teal", glyph: "star.fill"),
      to: "one")
    try layers.replace(layer: "empty", with: [])

    let data = try JSONEncoder().encode(CommandLayersSnapshot(layers))
    let back = try JSONDecoder().decode(CommandLayersSnapshot.self, from: data)
    let restored = try XCTUnwrap(CommandLayers(restoring: back))

    XCTAssertEqual(restored.layers.map(\.name), ["one", "empty"])
    XCTAssertEqual(restored.layers.map(\.accent), layers.layers.map(\.accent))
    XCTAssertEqual(restored.layer(named: "one")?.pins, layers.layer(named: "one")?.pins)
    XCTAssertEqual(restored.countedNames, ["one"])
    XCTAssertTrue(restored.layers.allSatisfy(\.isFromEarlierRun))
    XCTAssertTrue(restored.holdsEarlierRunPins)
  }

  /// Catches a snapshot read in part. A repeated ID, an unknown accent, or a newer version makes
  /// the whole snapshot unreadable.
  func testAnUnreadableSnapshotRestoresNothing() throws {
    var layers = CommandLayers()

    try layers.add(try pin("a"), to: "one")

    let good = CommandLayersSnapshot(layers)
    var repeated = good
    var newer = good
    var badAccent = good

    repeated.layers[0].pins.append(repeated.layers[0].pins[0])
    newer.version = 2
    badAccent.layers[0].accent = "base"

    XCTAssertNotNil(CommandLayers(restoring: good))
    XCTAssertNil(CommandLayers(restoring: repeated))
    XCTAssertNil(CommandLayers(restoring: newer))
    XCTAssertNil(CommandLayers(restoring: badAccent))
  }
}
