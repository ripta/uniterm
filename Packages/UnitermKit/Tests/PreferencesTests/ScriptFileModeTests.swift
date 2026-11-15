import Foundation
import XCTest

@testable import Preferences

@MainActor
final class ScriptFileModeTests: XCTestCase {
  private var suiteName = ""
  private var defaults: UserDefaults!

  override func setUp() async throws {
    suiteName = "uniterm.tests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
  }

  override func tearDown() async throws {
    defaults.removePersistentDomain(forName: suiteName)
  }

  /// Catches a default that runs undeclared files, which would let a fresh install run code that
  /// said nothing about its powers.
  func testDefaultsToStrict() {
    let store = SettingsStore(defaults: defaults)

    XCTAssertEqual(store.reading(of: .scriptFileMode), .unset(fallback: .strict))
    XCTAssertEqual(store.value(of: .scriptFileMode), .strict)
  }

  /// Catches a stored value this version does not know opening the permissive mode. Case and
  /// spelling variants of unsafe are unknown too, and none of them is written back.
  func testAnUnknownStoredValueReadsAsStrictAndIsNeverWrittenBack() {
    for raw in ["permissive", "Unsafe", "UNSAFE", "", "true"] {
      defaults.set(raw, forKey: "scriptFileMode")

      let store = SettingsStore(defaults: defaults)

      XCTAssertEqual(store.value(of: .scriptFileMode), .strict, raw)
      XCTAssertEqual(defaults.string(forKey: "scriptFileMode"), raw)
    }

    defaults.set(1, forKey: "scriptFileMode")

    XCTAssertEqual(SettingsStore(defaults: defaults).value(of: .scriptFileMode), .strict)
  }

  /// Catches a name or raw value that `defaults write` cannot reach.
  func testStoresThePlainRawStrings() {
    let store = SettingsStore(defaults: defaults)

    store.set(.unsafe, for: .scriptFileMode)

    XCTAssertEqual(defaults.string(forKey: "scriptFileMode"), "unsafe")
    XCTAssertEqual(store.value(of: .scriptFileMode), .unsafe)
  }
}
