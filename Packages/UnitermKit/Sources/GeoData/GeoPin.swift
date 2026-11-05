import Foundation
import ThemeCore

/// The mark on a pin's inner disc: one or two characters, or an SF Symbol name.
///
/// A name longer than two characters is a symbol, since no SF Symbol has a one- or two-character
/// name. Whether the running macOS has the symbol is decided when the pin is drawn. A missing one
/// shows the default glyph, and is not an error.
public enum PinGlyph: Sendable, Equatable {
  case text(String)
  case symbol(String)

  /// The longest SF Symbol name a pin takes. System names are far shorter.
  public static let maxSymbolLength = 64

  /// Reads a glyph from a string. Whitespace around it is trimmed. The result is nil for an empty
  /// string, a control character, and a name that is neither one or two characters nor shaped like
  /// an SF Symbol name: lowercase letters and digits in dot-separated parts.
  public init?(_ raw: String) {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !trimmed.isEmpty else { return nil }

    guard !trimmed.unicodeScalars.contains(where: \.isHiddenControl) else { return nil }

    if trimmed.count <= 2 {
      self = .text(trimmed)
      return
    }

    guard trimmed.utf8.count <= Self.maxSymbolLength, Self.isSymbolName(trimmed) else {
      return nil
    }

    self = .symbol(trimmed)
  }

  private static func isSymbolName(_ name: String) -> Bool {
    name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { part in
      !part.isEmpty
        && part.utf8.allSatisfy { ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) }
    }
  }
}

/// One pin on the map.
///
/// The accent is a palette token and never a color, so the pin follows the flavor. A nil accent
/// means the layer's default accent. A nil glyph means the default glyph.
public struct GeoPin: Sendable, Equatable {
  public let id: String
  public let coordinate: GeoCoordinate
  public let label: String
  public let accent: ThemeToken?
  public let glyph: PinGlyph?

  public init(
    id: String, coordinate: GeoCoordinate, label: String, accent: ThemeToken? = nil,
    glyph: PinGlyph? = nil
  ) {
    self.id = id
    self.coordinate = coordinate
    self.label = label
    self.accent = accent
    self.glyph = glyph
  }
}

extension Unicode.Scalar {
  /// True for a scalar a label or glyph must not carry. Controls, line and paragraph separators,
  /// and format characters can hide text or reorder it, as the bidirectional overrides do. The
  /// zero-width joiner and non-joiner stay, since emoji sequences and some scripts need them.
  var isHiddenControl: Bool {
    switch properties.generalCategory {
    case .control, .lineSeparator, .paragraphSeparator:
      return true

    case .format:
      return value != 0x200C && value != 0x200D

    default:
      return false
    }
  }
}
