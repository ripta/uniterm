import Foundation
import ThemeCore

/// Why a program's pin command was refused. The applet turns it into a structured error.
public struct CommandPinError: Error, Equatable, Sendable {
  public enum Kind: Sendable, Equatable {
    /// A value that does not fit the rules, such as an empty ID or an unknown accent.
    case badArgument

    /// A cap the pane keeps: pins per layer, pins per pane, or layers per pane.
    case capReached
  }

  public let kind: Kind
  public let message: String

  init(_ kind: Kind, _ message: String) {
    self.kind = kind
    self.message = message
  }
}

/// The bounds on what a program may place on a map, and the one rule that sizes the largest.
///
/// Every text bound counts UTF-8 bytes, never graphemes. A grapheme can hold any number of code
/// points, so a count of them bounds nothing.
public enum CommandPinLimits {
  /// The layer a command names when it names none. It is the same for every caller.
  public static let defaultLayerName = "default"

  public static let maxIDBytes = 64
  public static let maxLabelBytes = 128
  public static let maxGlyphBytes = 64
  public static let maxLayerNameBytes = 64

  /// The most pins one pane holds across every command layer.
  public static let maxPinsPerPane = 2_500

  /// The most command layers one pane holds, empty ones included. The file layer takes the first
  /// accent of the layer order, so 13 command layers and the file use all 14 accents once.
  public static let maxLayersPerPane = 13

  /// The most pins one layer holds, and so the most one `set-layer` carries. It is the largest
  /// count whose worst-case command still fits one exec frame. See `CommandFrameSizing`.
  public static let maxPinsPerLayer = CommandFrameSizing.pinsFitting(
    frameBytes: CommandFrameSizing.frameBytes, maxValues: CommandFrameSizing.maxValues,
    retainedBytes: CommandFrameSizing.retainedBytes)
}

/// The rule that sizes the per-layer pin cap from the exec wire's bounds.
///
/// The wire bounds a frame, the values in a frame, and the bytes retained for a driver. A full
/// `set-layer` must pass all three, whatever its text. The worst case is a pin whose every text
/// byte JSON escapes to six bytes, as `\u00XX` does, with each number at a fixed canonical length.
/// The cap is the smallest count any bound allows.
///
/// The bounds below mirror the exec protocol's. A test pins each against the protocol's own
/// constant, so a change there fails here.
public enum CommandFrameSizing {
  public static let frameBytes = 1 << 20
  public static let maxValues = 65_536
  public static let retainedBytes = 4 << 20

  /// The longest request ID a driver may choose, in UTF-8 bytes.
  public static let requestIDBytes = 64

  /// The most bytes JSON spends on one byte of text.
  public static let escapedBytesPerByte = 6

  /// The length a number is counted at. It fits the shortest form that round-trips a double, such
  /// as `-1.2345678901234567e-300`. A longer spelling takes room from the layer's pins.
  public static let canonicalNumberBytes = 24

  /// What the frame spends on a pin before its text and numbers: the keys, the punctuation, a
  /// longest accent name, and the comma that follows it.
  static let pinFixedBytes =
    #"{"id":,"coordinate":{"latitude":,"longitude":},"label":,"accent":"rosewater","glyph":},"#
    .utf8.count

  /// The values the wire counts in one pin: its braces, each key and string, and each comma. A
  /// number is counted by the comma that follows it, not by itself.
  static let pinValues = 20

  /// What the wire counts in a command that carries a pin array, beyond the pins. It covers a
  /// command addressed to another pane, which holds the most fields.
  static let envelopeValues = 64

  /// The bytes of the worst-case command around its pins: a pane command with the longest
  /// request ID, layer name, and numbers.
  static var envelopeBytes: Int {
    let fixed =
      #"{"type":"command","id":,"pane":9007199254740991,"applet":"map-viewer","schema":[2147483647,2147483647],"name":"set-layer","arguments":{"layer":,"pins":[]}}"#
      .utf8.count

    return fixed + escaped(requestIDBytes) + escaped(CommandPinLimits.maxLayerNameBytes)
  }

  /// The bytes of one string of `bytes` text bytes, with its quotes.
  static func escaped(_ bytes: Int) -> Int {
    bytes * escapedBytesPerByte + 2
  }

  /// The bytes of the worst-case pin, with the comma after it.
  public static var worstPinBytes: Int {
    pinFixedBytes + escaped(CommandPinLimits.maxIDBytes) + escaped(CommandPinLimits.maxLabelBytes)
      + escaped(CommandPinLimits.maxGlyphBytes) + 2 * canonicalNumberBytes
  }

  /// The bytes of a worst-case `set-layer` holding `pins` pins.
  public static func worstCommandBytes(pins: Int) -> Int {
    envelopeBytes + pins * worstPinBytes
  }

  /// The most pins whose worst-case command fits every bound.
  public static func pinsFitting(frameBytes: Int, maxValues: Int, retainedBytes: Int) -> Int {
    let bound = min(frameBytes, retainedBytes)
    let byBytes = (bound - envelopeBytes) / worstPinBytes
    let byValues = (maxValues - envelopeValues) / pinValues

    return max(0, min(byBytes, byValues))
  }
}

/// The checks a program's pin values pass before they become a `GeoPin`.
public enum CommandPins {
  /// The layer a command names, or the default layer when it names none.
  public static func layerName(_ raw: String?) throws(CommandPinError) -> String {
    guard let raw else { return CommandPinLimits.defaultLayerName }

    return try name(raw, what: "the layer name", maxBytes: CommandPinLimits.maxLayerNameBytes)
  }

  /// A pin's ID. It must be a non-empty name of visible text, since a driver and a person both
  /// read it.
  public static func pinID(_ raw: String) throws(CommandPinError) -> String {
    try name(raw, what: "the pin ID", maxBytes: CommandPinLimits.maxIDBytes)
  }

  private static func name(_ raw: String, what: String, maxBytes: Int) throws(CommandPinError)
    -> String
  {
    guard !raw.isEmpty else { throw CommandPinError(.badArgument, "\(what) is empty") }

    guard raw.utf8.count <= maxBytes else {
      throw CommandPinError(
        .badArgument, "\(what) is \(raw.utf8.count) bytes, and the most is \(maxBytes)")
    }

    guard !raw.unicodeScalars.contains(where: \.isHiddenControl) else {
      throw CommandPinError(.badArgument, "\(what) holds a control or invisible character")
    }

    return raw
  }

  /// Makes a pin from a program's values. An omitted label, or one with no visible text, takes
  /// the pin's coordinate, as a file pin does. A control or invisible character in a label
  /// becomes a space. An omitted accent or glyph stays nil, which means the layer's default
  /// accent and the default glyph.
  public static func pin(
    id: String, latitude: Double, longitude: Double, label: String?, accent: String?,
    glyph: String?
  ) throws(CommandPinError) -> GeoPin {
    let id = try pinID(id)

    guard latitude.isFinite, longitude.isFinite, abs(latitude) <= 90, abs(longitude) <= 180 else {
      throw CommandPinError(.badArgument, "the coordinate is off the globe")
    }

    let coordinate = GeoCoordinate(latitude: latitude, longitude: longitude)

    return GeoPin(
      id: id, coordinate: coordinate,
      label: try labelText(label) ?? GeoFileLayerBuilder.coordinateText(coordinate),
      accent: try accentToken(accent), glyph: try glyphValue(glyph))
  }

  static func labelText(_ raw: String?) throws(CommandPinError) -> String? {
    guard let raw else { return nil }

    guard raw.utf8.count <= CommandPinLimits.maxLabelBytes else {
      throw CommandPinError(
        .badArgument,
        "the label is \(raw.utf8.count) bytes, and the most is \(CommandPinLimits.maxLabelBytes)")
    }

    let cleaned = String(
      String.UnicodeScalarView(
        raw.unicodeScalars.map { $0.isHiddenControl ? " " : $0 }
      )
    ).trimmingCharacters(in: .whitespaces)

    return cleaned.isEmpty ? nil : cleaned
  }

  static func accentToken(_ raw: String?) throws(CommandPinError) -> ThemeToken? {
    guard let raw else { return nil }

    guard let token = ThemeToken(accent: raw) else {
      throw CommandPinError(.badArgument, "\"\(raw.prefix(32))\" is not an accent")
    }

    return token
  }

  static func glyphValue(_ raw: String?) throws(CommandPinError) -> PinGlyph? {
    guard let raw else { return nil }

    guard raw.utf8.count <= CommandPinLimits.maxGlyphBytes else {
      throw CommandPinError(
        .badArgument,
        "the glyph is \(raw.utf8.count) bytes, and the most is \(CommandPinLimits.maxGlyphBytes)")
    }

    guard let glyph = PinGlyph(raw) else {
      throw CommandPinError(
        .badArgument, "the glyph must be one or two characters, or an SF Symbol name")
    }

    return glyph
  }
}

/// One command layer: its name, the accent it keeps for the pane's life, and its pins in the order
/// they were placed.
public struct CommandLayer: Equatable, Sendable {
  public let name: String
  public let accent: ThemeToken
  public fileprivate(set) var pins: [GeoPin]

  /// True while the pins are from an earlier run, restored by a reopen, and no source has written
  /// the layer since.
  public fileprivate(set) var isFromEarlierRun: Bool

  fileprivate init(name: String, accent: ThemeToken, pins: [GeoPin], isFromEarlierRun: Bool) {
    self.name = name
    self.accent = accent
    self.pins = pins
    self.isFromEarlierRun = isFromEarlierRun
  }
}

/// What one change did to the layers, for the pane to draw and count.
public struct CommandLayerChange: Equatable, Sendable {
  public let layer: String

  /// True when the layer held pins in this launch for the first time, so the pane's count of
  /// layers that held pins grows by one.
  public let becameCounted: Bool

  /// True when the change cleared the earlier-run mark, so every pin of the layer is drawn again.
  public let clearedEarlierRun: Bool

  /// True when the change made the layer.
  public let created: Bool
}

/// The pins programs placed, by layer. This is the one store a pane's command layers live in.
///
/// Every mutation checks the whole change first and then applies it, so a refused change leaves
/// the layers as they were. Layers are never removed, empty ones included, so a layer keeps its
/// accent for the pane's life. The file layer is not here and no name reaches it.
public struct CommandLayers: Equatable, Sendable {
  public private(set) var layers: [CommandLayer] = []

  /// The names that held pins in this launch, so a rerun does not count a layer twice.
  public private(set) var countedNames: Set<String> = []

  public init() {}

  public var totalPins: Int { layers.reduce(0) { $0 + $1.pins.count } }

  public var isEmpty: Bool { layers.isEmpty }

  public func layer(named name: String) -> CommandLayer? {
    layers.first { $0.name == name }
  }

  /// True when a layer from an earlier run holds pins.
  public var holdsEarlierRunPins: Bool {
    layers.contains { $0.isFromEarlierRun && !$0.pins.isEmpty }
  }

  /// The accent the next new layer takes. Index 0 of the layer order is the file layer's.
  private var nextAccent: ThemeToken { PinAccents.layerDefault(at: layers.count + 1) }

  // MARK: Changes

  /// Places `pin` in `name`. A pin with the same ID is replaced whole, in its place.
  @discardableResult
  public mutating func add(_ pin: GeoPin, to name: String) throws(CommandPinError)
    -> CommandLayerChange
  {
    let index = layers.firstIndex { $0.name == name }
    let existing = index.flatMap { i in layers[i].pins.firstIndex { $0.id == pin.id } }

    if index == nil { try requireRoomForLayer() }

    if existing == nil {
      let held = index.map { layers[$0].pins.count } ?? 0

      try requireRoom(layerPins: held, paneAdds: 1)
    }

    let at = index ?? makeLayer(name)
    let cleared = layers[at].isFromEarlierRun

    if let existing {
      layers[at].pins[existing] = pin
    } else {
      layers[at].pins.append(pin)
    }

    layers[at].isFromEarlierRun = false

    return change(at, created: index == nil, clearedEarlierRun: cleared)
  }

  /// Replaces the whole contents of `name`. The pane's cap counts the pins after the replaced
  /// ones are gone. A repeated ID is refused, since the layer would hold one of the two.
  @discardableResult
  public mutating func replace(layer name: String, with pins: [GeoPin]) throws(CommandPinError)
    -> CommandLayerChange
  {
    let index = layers.firstIndex { $0.name == name }

    if index == nil { try requireRoomForLayer() }

    guard pins.count <= CommandPinLimits.maxPinsPerLayer else {
      throw CommandPinError(
        .capReached,
        "a layer holds at most \(CommandPinLimits.maxPinsPerLayer) pins, and this one has "
          + "\(pins.count)")
    }

    var seen = Set<String>()

    for pin in pins where !seen.insert(pin.id).inserted {
      throw CommandPinError(.badArgument, "the pin ID \"\(pin.id.prefix(16))\" is used twice")
    }

    let replaced = index.map { layers[$0].pins.count } ?? 0

    guard totalPins - replaced + pins.count <= CommandPinLimits.maxPinsPerPane else {
      throw CommandPinError(
        .capReached,
        "the pane holds at most \(CommandPinLimits.maxPinsPerPane) program pins across its layers")
    }

    let at = index ?? makeLayer(name)
    let cleared = layers[at].isFromEarlierRun

    layers[at].pins = pins
    layers[at].isFromEarlierRun = false

    return change(at, created: index == nil, clearedEarlierRun: cleared)
  }

  /// Removes the pin `id` from `name`. Returns nil when the layer has no such pin, which changes
  /// nothing.
  public mutating func remove(id: String, from name: String) -> CommandLayerChange? {
    guard let at = layers.firstIndex(where: { $0.name == name }),
      let pin = layers[at].pins.firstIndex(where: { $0.id == id })
    else { return nil }

    let cleared = layers[at].isFromEarlierRun

    layers[at].pins.remove(at: pin)
    layers[at].isFromEarlierRun = false

    return change(at, created: false, clearedEarlierRun: cleared)
  }

  /// Empties `name`. The layer stays and keeps its accent. Returns nil when there is no such layer.
  public mutating func clear(layer name: String) -> CommandLayerChange? {
    guard let at = layers.firstIndex(where: { $0.name == name }) else { return nil }

    let cleared = layers[at].isFromEarlierRun

    layers[at].pins = []
    layers[at].isFromEarlierRun = false

    return change(at, created: false, clearedEarlierRun: cleared)
  }

  /// Empties every layer, as the user's own clear does. The layers and their accents stay.
  public mutating func clearAll() -> [CommandLayerChange] {
    var changes: [CommandLayerChange] = []

    for name in layers.map(\.name) {
      if let change = clear(layer: name) { changes.append(change) }
    }

    return changes
  }

  // MARK: Support

  private func requireRoomForLayer() throws(CommandPinError) {
    guard layers.count < CommandPinLimits.maxLayersPerPane else {
      throw CommandPinError(
        .capReached,
        "the pane holds at most \(CommandPinLimits.maxLayersPerPane) layers, empty ones included")
    }
  }

  private func requireRoom(layerPins: Int, paneAdds: Int) throws(CommandPinError) {
    guard layerPins + paneAdds <= CommandPinLimits.maxPinsPerLayer else {
      throw CommandPinError(
        .capReached, "a layer holds at most \(CommandPinLimits.maxPinsPerLayer) pins")
    }

    guard totalPins + paneAdds <= CommandPinLimits.maxPinsPerPane else {
      throw CommandPinError(
        .capReached,
        "the pane holds at most \(CommandPinLimits.maxPinsPerPane) program pins across its layers")
    }
  }

  private mutating func makeLayer(_ name: String) -> Int {
    layers.append(
      CommandLayer(name: name, accent: nextAccent, pins: [], isFromEarlierRun: false))

    return layers.count - 1
  }

  private mutating func change(_ at: Int, created: Bool, clearedEarlierRun: Bool)
    -> CommandLayerChange
  {
    let name = layers[at].name
    let counts = !layers[at].pins.isEmpty && !countedNames.contains(name)

    if counts { countedNames.insert(name) }

    return CommandLayerChange(
      layer: name, becameCounted: counts, clearedEarlierRun: clearedEarlierRun, created: created)
  }
}

// MARK: - The undo-only part

/// The command layers as the undo-only part of a description stores them: names, accents, pins,
/// and the names that held pins in this launch. It never reaches the layout file.
public struct CommandLayersSnapshot: Codable, Equatable, Sendable {
  public static let currentVersion = 1

  struct PinRecord: Codable, Equatable, Sendable {
    var id: String
    var latitude: Double
    var longitude: Double
    var label: String
    var accent: String?
    var glyph: String?
  }

  struct LayerRecord: Codable, Equatable, Sendable {
    var name: String
    var accent: String
    var pins: [PinRecord]
  }

  var version: Int
  var counted: [String]
  var layers: [LayerRecord]

  public init(_ layers: CommandLayers) {
    version = Self.currentVersion
    counted = layers.countedNames.sorted()
    self.layers = layers.layers.map { layer in
      LayerRecord(
        name: layer.name, accent: layer.accent.rawValue,
        pins: layer.pins.map {
          PinRecord(
            id: $0.id, latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude,
            label: $0.label, accent: $0.accent?.rawValue, glyph: $0.glyph?.text)
        })
    }
  }
}

extension CommandLayers {
  /// Reads the layers a closed pane stored. Every pin is marked as from an earlier run.
  ///
  /// The stored values pass the same rules a command's do. Anything that does not, such as a
  /// version this build does not read, a name that is not valid, a repeated ID, or a count past a
  /// cap, makes the whole snapshot unreadable and returns nil. A partial read would show a layer
  /// the program never made.
  public init?(restoring snapshot: CommandLayersSnapshot) {
    guard snapshot.version == CommandLayersSnapshot.currentVersion,
      snapshot.layers.count <= CommandPinLimits.maxLayersPerPane
    else { return nil }

    var restored: [CommandLayer] = []
    var names = Set<String>()
    var total = 0

    for record in snapshot.layers {
      guard let name = try? CommandPins.layerName(record.name), names.insert(name).inserted,
        let accent = ThemeToken(accent: record.accent),
        record.pins.count <= CommandPinLimits.maxPinsPerLayer
      else { return nil }

      var ids = Set<String>()
      var pins: [GeoPin] = []

      for pin in record.pins {
        guard
          let made = try? CommandPins.pin(
            id: pin.id, latitude: pin.latitude, longitude: pin.longitude, label: pin.label,
            accent: pin.accent, glyph: pin.glyph),
          ids.insert(made.id).inserted
        else { return nil }

        pins.append(made)
      }

      total += pins.count
      restored.append(
        CommandLayer(name: name, accent: accent, pins: pins, isFromEarlierRun: true))
    }

    guard total <= CommandPinLimits.maxPinsPerPane,
      snapshot.counted.allSatisfy({ names.contains($0) })
    else { return nil }

    self.init()
    layers = restored
    countedNames = Set(snapshot.counted)
  }
}
