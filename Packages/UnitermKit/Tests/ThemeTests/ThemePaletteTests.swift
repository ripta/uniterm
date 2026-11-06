import XCTest

@testable import Theme

final class ThemePaletteTests: XCTestCase {
  /// Catches a mistyped hex value in the palette. The expected values are Catppuccin's published
  /// ones, typed again here. It cannot prove that the whole table is right.
  func testPublishedAnchorColors() {
    XCTAssertEqual(ThemePalette.latte[.base].hexString, "#eff1f5")
    XCTAssertEqual(ThemePalette.latte[.text].hexString, "#4c4f69")
    XCTAssertEqual(ThemePalette.latte[.red].hexString, "#d20f39")
    XCTAssertEqual(ThemePalette.mocha[.base].hexString, "#1e1e2e")
    XCTAssertEqual(ThemePalette.mocha[.text].hexString, "#cdd6f4")
    XCTAssertEqual(ThemePalette.mocha[.red].hexString, "#f38ba8")
  }

  /// Catches a token added to the enum without a value, and a flavor that reuses the other's value.
  func testEveryTokenDiffersBetweenFlavors() {
    XCTAssertEqual(ThemeToken.allCases.count, 26)
    for token in ThemeToken.allCases {
      XCTAssertNotEqual(ThemePalette.latte[token], ThemePalette.mocha[token], "\(token)")
    }
  }

  /// The terminal needs 16 ANSI colors in order. Catches a short table or a swapped pair.
  func testTerminalPaletteShape() {
    for palette in [ThemePalette.latte, ThemePalette.mocha] {
      let terminal = palette.terminal
      XCTAssertEqual(terminal.ansi.count, 16)
      XCTAssertEqual(terminal.background, palette[.base])
      XCTAssertEqual(terminal.foreground, palette[.text])
      XCTAssertEqual(terminal.ansi[1], palette[.red])
      XCTAssertEqual(terminal.ansi[2], palette[.green])
      XCTAssertEqual(terminal.ansi[4], palette[.blue])
    }
  }

  func testHexRoundTrip() {
    XCTAssertEqual(ThemeColor(hex: 0x04A5E5).hexString, "#04a5e5")
  }
}

/// The light or dark reading of a flavor, which applets hand to system views.
final class ThemeFlavorAppearanceTests: XCTestCase {
  /// Catches a flavor whose answer disagrees with its own surface color, and a new flavor that
  /// lands on the wrong side. The expectation reads the flavor's `base` brightness, apart from the
  /// property under test, so the two cannot drift together.
  func testEveryFlavorIsDarkExactlyWhenItsBaseSurfaceIsDark() {
    XCTAssertFalse(ThemeFlavor.allCases.isEmpty)

    for flavor in ThemeFlavor.allCases {
      let base = ThemePalette(flavor: flavor)[.base]
      let brightness = (Int(base.red) + Int(base.green) + Int(base.blue)) / 3

      XCTAssertEqual(flavor.isDark, brightness < 128, "\(flavor)")
    }
  }

  /// Catches a swapped pair. The shipped flavors are Latte, which is light, and Mocha, which is
  /// dark.
  func testTheShippedFlavors() {
    XCTAssertFalse(ThemeFlavor.latte.isDark)
    XCTAssertTrue(ThemeFlavor.mocha.isDark)
  }
}

/// The pin colors. The disc and glyph come from the flavor alone, so one pair per flavor proves
/// every accent.
final class PinColorTests: XCTestCase {
  /// Catches a disc or glyph token swap that drops the glyph below 4.5:1. The pair never depends on
  /// the accent, so this holds whatever accent sits behind the disc. It cannot prove how the
  /// glyph renders. The map's render test does.
  func testGlyphOnDiscReachesFourPointFiveInEveryFlavor() {
    for flavor in ThemeFlavor.allCases {
      let palette = ThemePalette(flavor: flavor)
      let ratio = palette.pinGlyph.contrastRatio(with: palette.pinDisc)

      XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(flavor)")
    }

    XCTAssertEqual(ThemePalette.latte.pinDisc, ThemePalette.latte[.base])
    XCTAssertEqual(ThemePalette.mocha.pinDisc, ThemePalette.mocha[.crust])
  }

  /// Catches a wrong WCAG formula. Black on white is 21, and equal colors are 1.
  func testContrastRatioMatchesTheWCAGEndpoints() {
    let black = ThemeColor(hex: 0x000000)
    let white = ThemeColor(hex: 0xFFFFFF)

    XCTAssertEqual(black.contrastRatio(with: white), 21, accuracy: 0.001)
    XCTAssertEqual(white.contrastRatio(with: black), 21, accuracy: 0.001)
    XCTAssertEqual(white.contrastRatio(with: white), 1, accuracy: 0.001)
  }

  /// Catches an accent set that gains a neutral token or loses a color.
  func testTheAccentSetIsTheFourteenColors() {
    XCTAssertEqual(ThemeToken.accents.count, 14)
    XCTAssertEqual(Set(ThemeToken.accents).count, 14)
    XCTAssertNil(ThemeToken(accent: "base"))
    XCTAssertNil(ThemeToken(accent: "chartreuse"))
    XCTAssertEqual(ThemeToken(accent: "teal"), .teal)
  }

  /// Catches an OKLab conversion that breaks the distance. Equal colors are at 0, and black to
  /// white is a lightness step of 1.
  func testOKLabDistance() {
    let black = ThemeColor(hex: 0x000000)
    let white = ThemeColor(hex: 0xFFFFFF)

    XCTAssertEqual(black.oklabDistance(to: black), 0, accuracy: 1e-9)
    XCTAssertEqual(black.oklabDistance(to: white), 1, accuracy: 0.01)
  }
}
