import Foundation
import ThemeCore

/// One GeoJSON object as the decoder left it, reduced to plain values.
///
/// The applet converts MapKit's decoded objects into this. Nothing here refers to MapKit, so the
/// rules below test without it and cross threads freely.
public struct GeoFeatureInput: Sendable, Equatable {
  /// The feature's `properties` object as JSON, or nil when it has none.
  public var propertiesJSON: Data?

  /// The coordinates of its Point and MultiPoint geometry, in file order.
  public var points: [GeoCoordinate]

  /// How many of its geometries were not points, or whether it had no geometry at all.
  public var skippedShapes: Int

  public init(propertiesJSON: Data? = nil, points: [GeoCoordinate], skippedShapes: Int = 0) {
    self.propertiesJSON = propertiesJSON
    self.points = points
    self.skippedShapes = skippedShapes
  }
}

/// The pins a file yields, and what the load left out.
public struct GeoFileLayer: Sendable, Equatable {
  public var pins: [GeoPin] = []

  /// Shapes that were not Point or MultiPoint, or features with no geometry.
  public var skippedShapes = 0

  /// Points with a coordinate off the globe or not a number.
  public var invalidCoordinates = 0

  /// Style values the map could not use. Each such value fell back to its default.
  public var unusableStyleValues = 0

  /// True when the file held more points than the bound and the rest were left out.
  public var truncated = false

  /// The lines the pane shows under the map, one per kind of loss. A clean load has none.
  public func notices(limit: Int) -> [String] {
    var lines: [String] = []

    if truncated {
      let count = limit.formatted()

      lines.append("The file has more than \(count) points. Showing the first \(count).")
    }

    if skippedShapes > 0 {
      lines.append(
        "Skipped \(skippedShapes.formatted()) \(skippedShapes == 1 ? "shape" : "shapes") that "
          + "\(skippedShapes == 1 ? "is" : "are") not points. The map shows points only.")
    }

    if invalidCoordinates > 0 {
      lines.append(
        "Skipped \(invalidCoordinates.formatted()) "
          + "\(invalidCoordinates == 1 ? "point" : "points") with coordinates off the globe.")
    }

    if unusableStyleValues > 0 {
      lines.append(
        "\(unusableStyleValues.formatted()) pin style "
          + "\(unusableStyleValues == 1 ? "value" : "values") could not be used. "
          + "Those pins use the default color or glyph.")
    }

    return lines
  }
}

/// Turns decoded GeoJSON objects into pins, by rules that are fixed and documented here.
///
/// The ID rule. A pin's ID is the object's ordinal in the file and the point's index within the
/// object, joined by a colon, as `3:0`. The ordinal counts every top-level object, including those
/// that give no pin, and starts at zero. The index counts the object's points in file order, so
/// the members of a MultiPoint are `3:0`, `3:1`, and so on. The GeoJSON `id` member is never used,
/// since it can be missing or repeat. Two pins of one file never share an ID.
///
/// The label rule. A pin's label is the first non-blank string among the properties `name`,
/// `title`, and `label`, in that order. Control characters, line and paragraph separators, and
/// invisible format characters such as the bidirectional overrides become spaces, so a file cannot
/// reorder the text around its label. The zero-width joiners that emoji sequences need stay. The
/// label is cut to `maxLabelLength` characters. With no usable property, the label is the
/// coordinate to five places.
///
/// The accent rule. The property `uniterm:accent` names an accent token and wins. Without a usable
/// one, `marker-color` is a simplestyle hex color, and the pin takes the nearest accent. The pin
/// stores the token. With neither, the accent is nil and the layer's default applies.
///
/// The glyph rule. The property `uniterm:glyph` is one or two characters or an SF Symbol name, and
/// wins. Without a usable one, `marker-symbol` of one or two characters is the glyph. A longer
/// `marker-symbol` is a Maki icon name. The map does not draw Maki icons, so it ignores the name
/// without counting it. With neither, the glyph is nil and the default glyph applies.
///
/// A value that is present but unusable falls through to the next source and adds one to
/// `unusableStyleValues`. A usable `uniterm:` value makes the simplestyle key moot, and the
/// simplestyle key is not read.
public struct GeoFileLayerBuilder {
  public static let maxLabelLength = 256
  public static let accentKey = "uniterm:accent"
  public static let glyphKey = "uniterm:glyph"
  public static let colorKey = "marker-color"
  public static let symbolKey = "marker-symbol"
  public static let labelKeys = ["name", "title", "label"]

  public let maxPoints: Int
  public private(set) var layer = GeoFileLayer()
  private var ordinal = 0

  public init(maxPoints: Int) {
    self.maxPoints = maxPoints
  }

  /// How many more points the layer takes.
  public var remaining: Int { max(0, maxPoints - layer.pins.count) }

  /// True once the layer holds as many pins as it may. Later objects only add to the counts the
  /// notices need, and their properties are never parsed.
  public var isFull: Bool { layer.pins.count >= maxPoints }

  /// Adds the next object of the file. Call it once per top-level object, in file order.
  public mutating func add(_ feature: GeoFeatureInput) {
    defer { ordinal += 1 }

    layer.skippedShapes += feature.skippedShapes

    guard !feature.points.isEmpty else { return }

    if isFull {
      for coordinate in feature.points {
        if Self.isOnTheGlobe(coordinate) {
          layer.truncated = true
        } else {
          layer.invalidCoordinates += 1
        }
      }

      return
    }

    let properties = Self.properties(of: feature.propertiesJSON)
    let label = Self.label(from: properties)
    var unusable = 0
    let accent = Self.accent(from: properties, unusable: &unusable)
    let glyph = Self.glyph(from: properties, unusable: &unusable)
    var counted = false

    for (index, coordinate) in feature.points.enumerated() {
      guard Self.isOnTheGlobe(coordinate) else {
        layer.invalidCoordinates += 1
        continue
      }

      guard layer.pins.count < maxPoints else {
        layer.truncated = true
        continue
      }

      layer.pins.append(
        GeoPin(
          id: "\(ordinal):\(index)", coordinate: coordinate,
          label: label ?? Self.coordinateText(coordinate), accent: accent, glyph: glyph))

      if !counted {
        layer.unusableStyleValues += unusable
        counted = true
      }
    }
  }

  static func isOnTheGlobe(_ coordinate: GeoCoordinate) -> Bool {
    coordinate.latitude.isFinite && coordinate.longitude.isFinite && abs(coordinate.latitude) <= 90
      && abs(coordinate.longitude) <= 180
  }

  /// The label of a pin with no label property: its coordinate to five places.
  public static func coordinateText(_ coordinate: GeoCoordinate) -> String {
    String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude)
  }

  static func properties(of json: Data?) -> [String: Any] {
    guard let json, !json.isEmpty,
      let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any]
    else { return [:] }

    return object
  }

  static func label(from properties: [String: Any]) -> String? {
    for key in labelKeys {
      guard let text = properties[key] as? String else { continue }

      let cleaned = String(
        text.unicodeScalars.map { $0.isHiddenControl ? " " : Character($0) }
      ).trimmingCharacters(in: .whitespacesAndNewlines)

      if !cleaned.isEmpty { return String(cleaned.prefix(maxLabelLength)) }
    }

    return nil
  }

  static func accent(from properties: [String: Any], unusable: inout Int) -> ThemeToken? {
    if let value = properties[accentKey] {
      if let name = value as? String, let token = ThemeToken(accent: name) { return token }

      unusable += 1
    }

    if let value = properties[colorKey] {
      if let text = value as? String, let color = PinAccents.parseHex(text) {
        return PinAccents.nearest(to: color)
      }

      unusable += 1
    }

    return nil
  }

  static func glyph(from properties: [String: Any], unusable: inout Int) -> PinGlyph? {
    if let value = properties[glyphKey] {
      if let text = value as? String, let glyph = PinGlyph(text) { return glyph }

      unusable += 1
    }

    if let value = properties[symbolKey] {
      guard let text = value as? String else {
        unusable += 1
        return nil
      }

      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

      if trimmed.isEmpty {
        unusable += 1
      } else if trimmed.count <= 2 {
        if let glyph = PinGlyph(trimmed) { return glyph }

        unusable += 1
      }
    }

    return nil
  }
}
