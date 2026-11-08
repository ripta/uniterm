/// The colors a terminal surface needs, derived from a flavor.
public struct TerminalPalette: Sendable, Equatable {
  public let foreground: ThemeColor
  public let background: ThemeColor
  public let cursor: ThemeColor
  public let cursorText: ThemeColor
  public let selectionBackground: ThemeColor
  public let selectionForeground: ThemeColor

  /// The 16 ANSI colors, indexed 0 through 15.
  public let ansi: [ThemeColor]
}

/// Every color token of one flavor. This file is the only place where raw color values live.
public struct ThemePalette: Sendable, Equatable {
  public let flavor: ThemeFlavor

  public init(flavor: ThemeFlavor) {
    self.flavor = flavor
  }

  public static let latte = ThemePalette(flavor: .latte)
  public static let mocha = ThemePalette(flavor: .mocha)

  public subscript(token: ThemeToken) -> ThemeColor {
    ThemeColor(hex: Self.hex(of: token, in: flavor))
  }

  /// The neutral disc a pin's glyph and a cluster's count sit on. It is `base` in Latte and `crust`
  /// in Mocha, so the disc is the lightest surface in Latte and the darkest in Mocha.
  public var pinDisc: ThemeColor {
    flavor.isDark ? self[.crust] : self[.base]
  }

  /// The color of a pin's glyph and a cluster's count. It is always `text`.
  ///
  /// The disc and the glyph depend on the flavor alone, never on the accent behind the disc, so
  /// their contrast is one number per flavor and holds for every accent.
  public var pinGlyph: ThemeColor {
    self[.text]
  }

  /// The text on a row highlighted in `blue`, such as the palette's and the launcher's selection.
  /// Latte's `base` reaches only 4.3:1 on its blue, so Latte uses white, which reaches 4.9:1.
  public var onAccent: ThemeColor {
    flavor.isDark ? self[.crust] : ThemeColor(hex: 0xFFFFFF)
  }

  /// Small secondary text on `mantle` or `base`, such as a row's applet name or directory. It is
  /// `subtext1`, the lightest shade that still reaches 4.5:1 on Latte's `mantle`.
  public var secondaryText: ThemeColor {
    self[.subtext1]
  }

  public var terminal: TerminalPalette {
    let ansiTokens: [ThemeToken]
    switch flavor {
    case .latte:
      ansiTokens = [
        .subtext1, .red, .green, .yellow, .blue, .pink, .teal, .surface2,
        .subtext0, .red, .green, .yellow, .blue, .pink, .teal, .surface1,
      ]
    case .mocha:
      ansiTokens = [
        .surface1, .red, .green, .yellow, .blue, .pink, .teal, .subtext1,
        .surface2, .red, .green, .yellow, .blue, .pink, .teal, .subtext0,
      ]
    }

    return TerminalPalette(
      foreground: self[.text],
      background: self[.base],
      cursor: self[.rosewater],
      cursorText: flavor == .latte ? self[.base] : self[.crust],
      selectionBackground: self[.surface2],
      selectionForeground: self[.text],
      ansi: ansiTokens.map { self[$0] })
  }

  private static func hex(of token: ThemeToken, in flavor: ThemeFlavor) -> UInt32 {
    switch flavor {
    case .latte: return latteHex(token)
    case .mocha: return mochaHex(token)
    }
  }

  private static func latteHex(_ token: ThemeToken) -> UInt32 {
    switch token {
    case .rosewater: return 0xDC8A78
    case .flamingo: return 0xDD7878
    case .pink: return 0xEA76CB
    case .mauve: return 0x8839EF
    case .red: return 0xD20F39
    case .maroon: return 0xE64553
    case .peach: return 0xFE640B
    case .yellow: return 0xDF8E1D
    case .green: return 0x40A02B
    case .teal: return 0x179299
    case .sky: return 0x04A5E5
    case .sapphire: return 0x209FB5
    case .blue: return 0x1E66F5
    case .lavender: return 0x7287FD
    case .text: return 0x4C4F69
    case .subtext1: return 0x5C5F77
    case .subtext0: return 0x6C6F85
    case .overlay2: return 0x7C7F93
    case .overlay1: return 0x8C8FA1
    case .overlay0: return 0x9CA0B0
    case .surface2: return 0xACB0BE
    case .surface1: return 0xBCC0CC
    case .surface0: return 0xCCD0DA
    case .base: return 0xEFF1F5
    case .mantle: return 0xE6E9EF
    case .crust: return 0xDCE0E8
    }
  }

  private static func mochaHex(_ token: ThemeToken) -> UInt32 {
    switch token {
    case .rosewater: return 0xF5E0DC
    case .flamingo: return 0xF2CDCD
    case .pink: return 0xF5C2E7
    case .mauve: return 0xCBA6F7
    case .red: return 0xF38BA8
    case .maroon: return 0xEBA0AC
    case .peach: return 0xFAB387
    case .yellow: return 0xF9E2AF
    case .green: return 0xA6E3A1
    case .teal: return 0x94E2D5
    case .sky: return 0x89DCEB
    case .sapphire: return 0x74C7EC
    case .blue: return 0x89B4FA
    case .lavender: return 0xB4BEFE
    case .text: return 0xCDD6F4
    case .subtext1: return 0xBAC2DE
    case .subtext0: return 0xA6ADC8
    case .overlay2: return 0x9399B2
    case .overlay1: return 0x7F849C
    case .overlay0: return 0x6C7086
    case .surface2: return 0x585B70
    case .surface1: return 0x45475A
    case .surface0: return 0x313244
    case .base: return 0x1E1E2E
    case .mantle: return 0x181825
    case .crust: return 0x11111B
    }
  }
}
