import DefaultsTestSupport
import Foundation
import XCTest

@testable import Preferences

@MainActor
final class PaletteModeTests: XCTestCase {
  private var testDefaults: TestDefaults!
  private var defaults: UserDefaults!

  override func setUp() async throws {
    testDefaults = TestDefaults()
    defaults = testDefaults.defaults
  }

  override func tearDown() async throws {
    testDefaults.discard()
  }

  /// Catches a default that docks the palette, which costs every window a row it did not ask for.
  func testDefaultsToFloatingAtTheTop() {
    let store = SettingsStore(defaults: defaults)

    XCTAssertEqual(store.reading(of: .paletteMode), .unset(fallback: .floating))
    XCTAssertEqual(store.reading(of: .paletteDockEdge), .unset(fallback: .top))
  }

  /// Catches key names or raw values that `defaults write` cannot reach.
  func testStoresThePlainRawStrings() {
    let store = SettingsStore(defaults: defaults)

    store.set(.docked, for: .paletteMode)
    store.set(.bottom, for: .paletteDockEdge)

    XCTAssertEqual(defaults.string(forKey: "paletteMode"), "docked")
    XCTAssertEqual(defaults.string(forKey: "paletteDockEdge"), "bottom")
  }

  /// Catches a fallback that rewrites the stored text, or reads an unknown value as valid.
  func testUnknownValuesFallBackAndAreNeverWrittenBack() {
    defaults.set("sideways", forKey: "paletteMode")
    defaults.set("left", forKey: "paletteDockEdge")
    let store = SettingsStore(defaults: defaults)

    XCTAssertEqual(store.reading(of: .paletteMode), .invalid(raw: "sideways", fallback: .floating))
    XCTAssertEqual(store.reading(of: .paletteDockEdge), .invalid(raw: "left", fallback: .top))
    XCTAssertEqual(defaults.string(forKey: "paletteMode"), "sideways")
  }
}
