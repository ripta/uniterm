import Foundation
import ThemeCore

/// One change the user makes to a file's pins.
public enum PinEdit: Sendable, Equatable {
  /// Gives the pin `old` the coordinate, label, accent, and glyph of `new`. Both carry the same ID.
  case update(old: GeoPin, new: GeoPin)

  case remove(GeoPin)

  /// Adds a pin. Its ID is ignored, since the file's order gives the new pin its ID.
  case add(GeoPin)
}

/// Why an edit could not be made. The text is shown to the user.
public enum PinEditError: Error, Equatable, Sendable, LocalizedError {
  /// No pin in the document has this ID, as when the file changed since the pins were read.
  case notFound(String)

  /// The pin sits where the map cannot change it without rewriting shapes it does not show.
  case notEditable(String)

  /// The document is not JSON the patcher can read.
  case unreadable(JSONSpanError)

  public var errorDescription: String? {
    switch self {
    case .notFound:
      return "That pin is no longer in the file. Reopen the file and try again."

    case .notEditable:
      return
        "That pin is part of a geometry collection. The map changes only Point and MultiPoint "
        + "shapes, so edit this one in another program."

    case .unreadable(let error):
      return "The file could not be read for editing: \(error.reason) at byte \(error.offset)."
    }
  }
}

/// Applies pin edits to a GeoJSON document's bytes, and leaves every other byte as it was.
///
/// The map reads a file through `MKGeoJSONDecoder`, which keeps no formatting and drops what it
/// does not show. A save written from that would lose lines, polygons, unknown properties, and the
/// author's layout. The patcher works on the file's own bytes instead. It finds the feature a pin
/// came from by the pin ID rule in `GeoFileLayerBuilder`, and replaces only the values the edit
/// changes.
///
/// The rules, by edit:
///
/// - Moving a Point rewrites its coordinates array. Moving a member of a MultiPoint rewrites that
///   member only. An altitude, or any value past the second, is kept.
/// - Changing a label replaces the first non-blank of `name`, `title`, and `label`, or adds `name`.
///   A blank label removes it, so the pin shows its coordinate.
/// - Changing an accent or a glyph sets `uniterm:accent` or `uniterm:glyph`, which win over the
///   simplestyle keys. Choosing the default removes the key. A `marker-color` or `marker-symbol`
///   then applies again.
/// - Restyling a member of a MultiPoint with more than one member moves it out to a Point feature
///   of its own, with a copy of the properties, appended to the collection.
/// - Removing a Point, or the last member of a MultiPoint, removes the feature. Removing another
///   member removes it from the MultiPoint.
/// - Adding appends a Point feature to the collection.
///
/// A document whose top level is one Feature or one bare geometry is first wrapped in a
/// FeatureCollection, with the original bytes inside it unchanged. A pin in a geometry
/// collection cannot be changed, since its feature's other shapes would have to be rewritten.
public enum GeoJSONPatcher {
  /// What a new file starts as.
  public static let emptyDocument = Data(
    "{\n  \"type\": \"FeatureCollection\",\n  \"features\": [\n  ]\n}\n".utf8)

  public static func apply(_ edit: PinEdit, to data: Data) throws -> Data {
    var bytes = [UInt8](data)

    do {
      bytes = try wrappedInCollection(bytes)

      let document = try Collection(bytes)
      let changes = try document.changes(for: edit)

      return Data(replacing(changes, in: bytes))
    } catch let error as JSONSpanError {
      throw PinEditError.unreadable(error)
    }
  }

  // MARK: Changes

  /// A run of bytes to replace. An empty range inserts.
  struct Change {
    let range: Range<Int>
    let text: [UInt8]
  }

  static func replacing(_ changes: [Change], in bytes: [UInt8]) -> [UInt8] {
    var result = bytes

    for change in changes.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
      result.replaceSubrange(change.range, with: change.text)
    }

    return result
  }

  /// The document with a FeatureCollection at its top, and any text around the top value kept.
  static func wrappedInCollection(_ bytes: [UInt8]) throws -> [UInt8] {
    let spans = JSONSpans(bytes)
    let root = try spans.root()
    let members = try spans.members(of: root)
    let type = members.first { $0.key == "type" }.flatMap { spans.stringValue($0.valueSpan) }

    if type == "FeatureCollection" { return bytes }

    var feature = Array(bytes[root])

    if type != "Feature" {
      feature =
        Array(#"{"type": "Feature", "properties": null, "geometry": "#.utf8) + feature + [0x7D]
    }

    let wrapped =
      Array(#"{"type": "FeatureCollection", "features": ["#.utf8) + feature + [0x5D, 0x7D]

    return Array(bytes[..<root.lowerBound]) + wrapped + Array(bytes[root.upperBound...])
  }

  // MARK: Reading the collection

  /// Where a FeatureCollection's features sit.
  struct Collection {
    let spans: JSONSpans
    let featuresSpan: Range<Int>
    let features: [Range<Int>]

    init(_ bytes: [UInt8]) throws {
      spans = JSONSpans(bytes)

      let root = try spans.root()

      guard let member = try spans.members(of: root).first(where: { $0.key == "features" }) else {
        throw JSONSpanError(offset: root.lowerBound, reason: "the collection has no features")
      }

      featuresSpan = member.valueSpan
      features = try spans.elements(of: featuresSpan)
    }

    func changes(for edit: PinEdit) throws -> [Change] {
      switch edit {
      case .add(let pin):
        return [append(Writer.feature(pin, properties: Writer.properties(for: pin)))]

      case .remove(let pin):
        let point = try locate(pin.id)

        if point.memberCount <= 1 {
          return [cut(element: point.ordinal, of: features, in: featuresSpan)]
        }

        return [cut(element: point.index, of: point.coordinates, in: point.coordinatesSpan)]

      case .update(let old, let new):
        return try update(old: old, new: new)
      }
    }

    private func update(old: GeoPin, new: GeoPin) throws -> [Change] {
      let point = try locate(old.id)
      let moved = old.coordinate != new.coordinate
      let restyled = old.label != new.label || old.accent != new.accent || old.glyph != new.glyph

      if restyled, point.memberCount > 1 {
        let properties = try point.properties.map { try restyledObject($0, old: old, new: new) }

        return [
          cut(element: point.index, of: point.coordinates, in: point.coordinatesSpan),
          append(Writer.feature(new, properties: properties ?? Writer.properties(for: new))),
        ]
      }

      var changes: [Change] = []

      if moved {
        let target =
          point.memberCount == 1 && !point.isMulti
          ? point.coordinatesSpan : point.coordinates[point.index]
        changes.append(
          Change(range: target, text: try coordinateText(new.coordinate, replacing: target)))
      }

      if restyled {
        if let properties = point.properties {
          changes += try restyle(properties, old: old, new: new)
        } else if let null = point.nullProperties {
          changes.append(Change(range: null, text: Writer.properties(for: new)))
        } else {
          changes.append(
            insertMember("properties", Writer.properties(for: new), into: point.feature))
        }
      }

      return changes
    }

    // MARK: Locating a pin

    struct Point {
      let ordinal: Int
      let index: Int
      let feature: Range<Int>
      let isMulti: Bool
      let coordinatesSpan: Range<Int>
      let coordinates: [Range<Int>]
      let properties: Range<Int>?
      let nullProperties: Range<Int>?

      var memberCount: Int { isMulti ? coordinates.count : 1 }
    }

    func locate(_ id: String) throws -> Point {
      let parts = id.split(separator: ":")

      guard parts.count == 2, let ordinal = Int(parts[0]), let index = Int(parts[1]),
        features.indices.contains(ordinal)
      else { throw PinEditError.notFound(id) }

      let feature = features[ordinal]
      let members = try spans.members(of: feature)

      guard let geometry = members.first(where: { $0.key == "geometry" })?.valueSpan,
        !spans.isNull(geometry)
      else { throw PinEditError.notFound(id) }

      let shape = try spans.members(of: geometry)
      let type = shape.first { $0.key == "type" }.flatMap { spans.stringValue($0.valueSpan) }

      guard let coordinatesSpan = shape.first(where: { $0.key == "coordinates" })?.valueSpan else {
        throw PinEditError.notEditable(id)
      }

      let isMulti: Bool

      switch type {
      case "Point": isMulti = false
      case "MultiPoint": isMulti = true
      default: throw PinEditError.notEditable(id)
      }

      let coordinates = isMulti ? try spans.elements(of: coordinatesSpan) : [coordinatesSpan]

      guard coordinates.indices.contains(index) else { throw PinEditError.notFound(id) }

      let property = members.first { $0.key == "properties" }?.valueSpan
      let isObject = property.map { spans.bytes[$0.lowerBound] == 0x7B } ?? false

      return Point(
        ordinal: ordinal, index: index, feature: feature, isMulti: isMulti,
        coordinatesSpan: coordinatesSpan, coordinates: coordinates,
        properties: isObject ? property : nil,
        nullProperties: property.flatMap { spans.isNull($0) ? $0 : nil })
    }

    // MARK: Arrays

    /// Appends `text` to the features array, separated as its last two elements are.
    func append(_ text: [UInt8]) -> Change {
      let bytes = spans.bytes

      guard let last = features.last else {
        let inner = Array(bytes[(featuresSpan.lowerBound + 1)..<(featuresSpan.upperBound - 1)])

        guard let newline = inner.lastIndex(of: 0x0A) else {
          return Change(
            range: (featuresSpan.lowerBound + 1)..<(featuresSpan.lowerBound + 1), text: text)
        }

        let closing = Array(inner[(newline + 1)...])

        return Change(
          range: (featuresSpan.lowerBound + 1)..<(featuresSpan.lowerBound + 1),
          text: [0x0A] + closing + Array("  ".utf8) + text)
      }

      let separator: [UInt8]

      if features.count > 1 {
        separator = Array(bytes[features[features.count - 2].upperBound..<last.lowerBound])
      } else {
        separator = [0x2C] + Array(bytes[(featuresSpan.lowerBound + 1)..<last.lowerBound])
      }

      return Change(range: last.upperBound..<last.upperBound, text: separator + text)
    }

    /// Removes one element of an array, with the comma and space that set it apart.
    func cut(element index: Int, of elements: [Range<Int>], in span: Range<Int>) -> Change {
      let element = elements[index]

      if index + 1 < elements.count {
        return Change(range: element.lowerBound..<elements[index + 1].lowerBound, text: [])
      }

      if index > 0 {
        return Change(range: elements[index - 1].upperBound..<element.upperBound, text: [])
      }

      return Change(range: element, text: [])
    }

    // MARK: Coordinates

    /// The text for `coordinate` in place of the coordinate array at `target`, keeping an
    /// altitude and the array's own separator.
    func coordinateText(_ coordinate: GeoCoordinate, replacing target: Range<Int>) throws -> [UInt8]
    {
      let parts = try spans.elements(of: target)
      let bytes = spans.bytes
      let separator =
        parts.count > 1 ? Array(bytes[parts[0].upperBound..<parts[1].lowerBound]) : Array(", ".utf8)
      let rest = parts.dropFirst(2).map { Array(bytes[$0]) }
      let values = [Writer.number(coordinate.longitude), Writer.number(coordinate.latitude)] + rest

      return [0x5B] + Array(values.joined(separator: separator)) + [0x5D]
    }

    // MARK: Properties

    /// The property changes `old` to `new` needs, made in place when they only replace values.
    func restyle(_ span: Range<Int>, old: GeoPin, new: GeoPin) throws -> [Change] {
      let members = try spans.members(of: span)
      let plan = try plan(members: members, old: old, new: new)

      if plan.removals.isEmpty, plan.insertions.isEmpty {
        return plan.replacements.map { Change(range: $0.key, text: $0.value) }
      }

      return [Change(range: span, text: try restyledObject(span, old: old, new: new))]
    }

    /// The whole properties object at `span`, rewritten for `new`. Members the edit does not touch
    /// keep their bytes, and the object keeps its own separators.
    func restyledObject(_ span: Range<Int>, old: GeoPin, new: GeoPin) throws -> [UInt8] {
      let members = try spans.members(of: span)
      let plan = try plan(members: members, old: old, new: new)
      let bytes = spans.bytes

      var texts: [[UInt8]] = []
      var colon = Array(": ".utf8)

      if let first = members.first {
        colon = Array(bytes[first.keySpan.upperBound..<first.valueSpan.lowerBound])
      }

      for member in members where !plan.removals.contains(member.key) {
        let value = plan.replacements[member.valueSpan] ?? Array(bytes[member.valueSpan])
        texts.append(Array(bytes[member.keySpan.lowerBound..<member.valueSpan.lowerBound]) + value)
      }

      for (key, value) in plan.insertions {
        texts.append(Writer.string(key) + colon + value)
      }

      var separator = Array(", ".utf8)
      var opening: [UInt8] = []
      var closing: [UInt8] = []

      if members.count > 1 {
        separator = Array(bytes[members[0].valueSpan.upperBound..<members[1].keySpan.lowerBound])
      }

      if let first = members.first, let last = members.last {
        opening = Array(bytes[(span.lowerBound + 1)..<first.keySpan.lowerBound])
        closing = Array(bytes[last.valueSpan.upperBound..<(span.upperBound - 1)])

        if members.count == 1, opening.contains(0x0A) {
          separator = [0x2C] + opening
        }
      }

      return [0x7B] + opening + Array(texts.joined(separator: separator)) + closing + [0x7D]
    }

    struct Plan {
      var replacements: [Range<Int>: [UInt8]] = [:]
      var removals: Set<String> = []
      var insertions: [(String, [UInt8])] = []
    }

    func plan(members: [JSONMember], old: GeoPin, new: GeoPin) throws -> Plan {
      var plan = Plan()

      if old.label != new.label {
        let label = new.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = GeoFileLayerBuilder.labelKeys.lazy.compactMap { key in
          members.first { member in
            member.key == key
              && spans.stringValue(member.valueSpan).map {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              } == true
          }
        }.first

        if label.isEmpty || label == GeoFileLayerBuilder.coordinateText(new.coordinate) {
          if let current { plan.removals.insert(current.key) }
        } else if let current {
          plan.replacements[current.valueSpan] = Writer.string(label)
        } else {
          plan.insertions.append(("name", Writer.string(label)))
        }
      }

      if old.accent != new.accent {
        set(GeoFileLayerBuilder.accentKey, to: new.accent.map { Writer.string($0.rawValue) })
      }

      if old.glyph != new.glyph {
        set(GeoFileLayerBuilder.glyphKey, to: new.glyph.map { Writer.string($0.text) })
      }

      func set(_ key: String, to value: [UInt8]?) {
        let member = members.first { $0.key == key }

        switch (member, value) {
        case (let member?, let value?): plan.replacements[member.valueSpan] = value
        case (let member?, nil): plan.removals.insert(member.key)
        case (nil, let value?): plan.insertions.append((key, value))
        case (nil, nil): break
        }
      }

      return plan
    }

    /// Adds a member at the front of an object, so a feature with no properties gains them.
    func insertMember(_ key: String, _ value: [UInt8], into object: Range<Int>) -> Change {
      let at = object.lowerBound + 1
      let isEmpty = spans.skipWhitespace(from: at) == object.upperBound - 1
      let text = Writer.string(key) + Array(": ".utf8) + value + (isEmpty ? [] : Array(", ".utf8))

      return Change(range: at..<at, text: text)
    }
  }

  // MARK: Writing

  /// The text of the values the patcher writes.
  enum Writer {
    static func number(_ value: Double) -> [UInt8] {
      Array(String(describing: value).utf8)
    }

    static func string(_ text: String) -> [UInt8] {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.withoutEscapingSlashes]

      return [UInt8]((try? encoder.encode(text)) ?? Data("\"\"".utf8))
    }

    /// A properties object holding only what `pin` sets.
    static func properties(for pin: GeoPin) -> [UInt8] {
      var members: [[UInt8]] = []
      let label = pin.label.trimmingCharacters(in: .whitespacesAndNewlines)

      if !label.isEmpty, label != GeoFileLayerBuilder.coordinateText(pin.coordinate) {
        members.append(string("name") + Array(": ".utf8) + string(label))
      }

      if let accent = pin.accent {
        members.append(
          string(GeoFileLayerBuilder.accentKey) + Array(": ".utf8) + string(accent.rawValue))
      }

      if let glyph = pin.glyph {
        members.append(
          string(GeoFileLayerBuilder.glyphKey) + Array(": ".utf8) + string(glyph.text))
      }

      return [0x7B] + Array(members.joined(separator: Array(", ".utf8))) + [0x7D]
    }

    static func feature(_ pin: GeoPin, properties: [UInt8]) -> [UInt8] {
      let coordinates =
        [0x5B] + number(pin.coordinate.longitude) + Array(", ".utf8)
        + number(pin.coordinate.latitude)
        + [0x5D]

      return Array(#"{"type": "Feature", "properties": "#.utf8) + properties
        + Array(#", "geometry": {"type": "Point", "coordinates": "#.utf8) + coordinates
        + Array("}}".utf8)
    }
  }
}
