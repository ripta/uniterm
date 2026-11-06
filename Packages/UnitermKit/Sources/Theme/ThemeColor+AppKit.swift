import AppKit
// Theme keeps the AppKit side of the palette. The tokens, flavors, color values, and color math
// live in ThemeCore, which has no AppKit, and every `import Theme` still sees them.
@_exported import ThemeCore

extension ThemeColor {
  public var nsColor: NSColor {
    NSColor(
      srgbRed: CGFloat(red) / 255,
      green: CGFloat(green) / 255,
      blue: CGFloat(blue) / 255,
      alpha: 1)
  }

  public var cgColor: CGColor {
    nsColor.cgColor
  }
}
