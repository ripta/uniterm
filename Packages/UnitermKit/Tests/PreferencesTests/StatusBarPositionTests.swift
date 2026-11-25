import DefaultsTestSupport
import Foundation
import XCTest

@testable import Preferences

@MainActor
final class StatusBarPositionTests: XCTestCase {
  private var testDefaults: TestDefaults!
  private var defaults: UserDefaults!

  override func setUp() async throws {
    testDefaults = TestDefaults()
    defaults = testDefaults.defaults
  }

  override func tearDown() async throws {
    testDefaults.discard()
  }

  /// Catches a default that moves the bar away from where it has always sat.
  func testDefaultsToBottomWhenUnset() {
    let store = SettingsStore(defaults: defaults)

    XCTAssertEqual(store.reading(of: .statusBarPosition), .unset(fallback: .bottom))
  }

  /// Catches a key name or raw values that `defaults write` cannot reach.
  func testStoresThePlainRawString() {
    let store = SettingsStore(defaults: defaults)

    store.set(.top, for: .statusBarPosition)

    XCTAssertEqual(defaults.string(forKey: "statusBarPosition"), "top")
    XCTAssertEqual(store.value(of: .statusBarPosition), .top)
  }

  /// Catches a fallback that rewrites the stored value.
  func testUnknownValueFallsBackAndIsNeverWrittenBack() {
    defaults.set("sideways", forKey: "statusBarPosition")
    let store = SettingsStore(defaults: defaults)

    XCTAssertEqual(store.value(of: .statusBarPosition), .bottom)
    XCTAssertEqual(
      store.reading(of: .statusBarPosition), .invalid(raw: "sideways", fallback: .bottom))
    XCTAssertEqual(defaults.string(forKey: "statusBarPosition"), "sideways")
  }

  /// Catches a store that misreads a write from another process.
  ///
  /// The write is a real `defaults` child. The store must notify and classify the value as
  /// invalid. Whether the window leaves the stored text alone is covered in the window tests.
  func testUnknownValueFromAnotherProcessIsReportedAsInvalid() async throws {
    let store = SettingsStore(defaults: defaults)
    store.watch(.statusBarPosition)

    let changed = expectation(description: "observer ran")
    changed.assertForOverFulfill = false
    let observation = store.addObserver { changed.fulfill() }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
    process.arguments = ["write", testDefaults.suite, "statusBarPosition", "-string", "sideways"]
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)

    await fulfillment(of: [changed], timeout: 10)

    XCTAssertEqual(
      store.reading(of: .statusBarPosition), .invalid(raw: "sideways", fallback: .bottom))
    XCTAssertEqual(store.value(of: .statusBarPosition), .bottom)
    observation.cancel()
  }
}
