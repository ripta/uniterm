import Foundation
import ThemeCore

/// The rules that choose a pin's accent.
public enum PinAccents {
  /// The accents a layer takes as its default, in order. The first layer takes the first accent,
  /// the second layer the second, and so on, and the list repeats after 14 layers.
  ///
  /// The order is fixed so a layer's color does not depend on what else is open. Neighbors are
  /// far apart in color, in both flavors. The reddish accents rosewater, flamingo, maroon, and
  /// red are never next to each other, and rosewater is never followed by flamingo. A test pins
  /// the order and the neighbor rule.
  public static let layerOrder: [ThemeToken] = [
    .blue, .peach, .green, .mauve, .yellow, .teal, .red, .pink, .sapphire, .maroon, .lavender,
    .flamingo, .sky, .rosewater,
  ]

  /// The default accent of the layer at `index`, counting from zero.
  public static func layerDefault(at index: Int) -> ThemeToken {
    layerOrder[((index % layerOrder.count) + layerOrder.count) % layerOrder.count]
  }

  /// The accent a stored name means, or nil when the name is not an accent token.
  public static func validated(_ stored: String?) -> ThemeToken? {
    stored.flatMap { ThemeToken(accent: $0) }
  }

  /// The accent nearest `color` by distance in OKLab, measured against Latte.
  ///
  /// Latte is the one reference flavor, so a color maps to the same accent whatever flavor is
  /// showing, and the pin stores the token. A tie goes to the earlier accent in
  /// `ThemeToken.accents`.
  public static func nearest(to color: ThemeColor) -> ThemeToken {
    let reference = ThemePalette.latte
    var best = ThemeToken.accents[0]
    var bestDistance = Double.infinity

    for token in ThemeToken.accents {
      let distance = color.oklabDistance(to: reference[token])

      if distance < bestDistance {
        best = token
        bestDistance = distance
      }
    }

    return best
  }

  /// Reads a simplestyle color: `#rgb` or `#rrggbb`, with or without the `#`, in either case.
  public static func parseHex(_ text: String) -> ThemeColor? {
    var digits = Substring(text.trimmingCharacters(in: .whitespaces))

    if digits.hasPrefix("#") { digits = digits.dropFirst() }

    guard digits.count == 3 || digits.count == 6, digits.utf8.allSatisfy(\.isHexDigit) else {
      return nil
    }

    if digits.count == 3 {
      digits = Substring(digits.map { "\($0)\($0)" }.joined())
    }

    return UInt32(digits, radix: 16).map { ThemeColor(hex: $0) }
  }
}

extension UInt8 {
  fileprivate var isHexDigit: Bool {
    (self >= 0x30 && self <= 0x39) || (self >= 0x41 && self <= 0x46)
      || (self >= 0x61 && self <= 0x66)
  }
}
