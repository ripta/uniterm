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
