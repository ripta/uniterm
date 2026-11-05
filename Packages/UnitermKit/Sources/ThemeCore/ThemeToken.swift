/// Which Catppuccin flavor a palette uses.
public enum ThemeFlavor: String, Sendable, CaseIterable {
  case latte
  case mocha

  /// True when the flavor's surfaces are dark. An applet that hands its colors to a system view
  /// reads this to pick that view's light or dark appearance. A new flavor must answer here, since
  /// the switch has no default.
  public var isDark: Bool {
    switch self {
    case .latte: return false
    case .mocha: return true
    }
  }
}

/// A named color. Applets and regions read colors by token and never carry raw values.
///
/// The names and values are Catppuccin's.
public enum ThemeToken: String, Sendable, CaseIterable {
  case rosewater, flamingo, pink, mauve, red, maroon, peach, yellow, green, teal, sky, sapphire
  case blue, lavender
  case text, subtext1, subtext0
  case overlay2, overlay1, overlay0
  case surface2, surface1, surface0
  case base, mantle, crust
}

extension ThemeToken {
  /// The closed set of accent tokens a pin may carry, in Catppuccin's order. A pin's color is one
  /// of these and never a raw value, so it follows the flavor.
  public static let accents: [ThemeToken] = [
    .rosewater, .flamingo, .pink, .mauve, .red, .maroon, .peach, .yellow, .green, .teal, .sky,
    .sapphire, .blue, .lavender,
  ]

  public var isAccent: Bool { Self.accents.contains(self) }

  /// The accent named `name`, or nil when `name` is not one of the accent tokens. A neutral token
  /// such as `base` is not an accent.
  public init?(accent name: String) {
    guard let token = ThemeToken(rawValue: name), token.isAccent else { return nil }

    self = token
  }
}
