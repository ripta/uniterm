import Foundation

/// An sRGB color with 8 bits per channel.
public struct ThemeColor: Sendable, Hashable {
  public let red: UInt8
  public let green: UInt8
  public let blue: UInt8

  public init(hex: UInt32) {
    red = UInt8((hex >> 16) & 0xFF)
    green = UInt8((hex >> 8) & 0xFF)
    blue = UInt8(hex & 0xFF)
  }

  /// The color as lowercase `#rrggbb`.
  public var hexString: String {
    String(format: "#%02x%02x%02x", red, green, blue)
  }
}

extension ThemeColor {
  /// The WCAG relative luminance, from 0 for black to 1 for white.
  public var relativeLuminance: Double {
    func linear(_ channel: UInt8) -> Double {
      let value = Double(channel) / 255

      return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
  }

  /// The WCAG contrast ratio against `other`, from 1 for equal colors to 21 for black on white.
  /// The order of the two colors does not matter.
  public func contrastRatio(with other: ThemeColor) -> Double {
    let first = relativeLuminance
    let second = other.relativeLuminance

    return (max(first, second) + 0.05) / (min(first, second) + 0.05)
  }

  /// The color in OKLab as lightness, a, and b. Euclidean distance in this space tracks perceived
  /// difference far better than distance in sRGB.
  public var oklab: (lightness: Double, a: Double, b: Double) {
    func linear(_ channel: UInt8) -> Double {
      let value = Double(channel) / 255

      return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    let r = linear(red)
    let g = linear(green)
    let b = linear(blue)

    let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
    let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
    let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)

    return (
      0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
      1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
      0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
    )
  }

  /// The Euclidean distance to `other` in OKLab.
  public func oklabDistance(to other: ThemeColor) -> Double {
    let first = oklab
    let second = other.oklab

    let dl = first.lightness - second.lightness
    let da = first.a - second.a
    let db = first.b - second.b

    return (dl * dl + da * da + db * db).squareRoot()
  }
}
