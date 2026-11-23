import DefaultsTestSupport
import Foundation
import XCTest

@testable import Preferences

@MainActor
final class SettingsStoreTests: XCTestCase {
  private var testDefaults: TestDefaults!
  private var defaults: UserDefaults!

  override func setUp() async throws {
    testDefaults = TestDefaults()
    defaults = testDefaults.defaults
  }

  override func tearDown() async throws {
    testDefaults.discard()
  }

  func testDefaultsToSystemWhenUnset() {
    let store = SettingsStore(defaults: defaults)
    XCTAssertEqual(store.reading(of: .appearance), .unset(fallback: .system))
    XCTAssertEqual(store.value(of: .appearance), .system)
  }

  /// Catches a fallback that rewrites the stored value. The invalid value must survive the read.
  func testInvalidValueFallsBackAndIsNeverWrittenBack() {
    defaults.set("sepia", forKey: "appearance")
    let store = SettingsStore(defaults: defaults)

    XCTAssertEqual(store.value(of: .appearance), .system)
    XCTAssertEqual(store.reading(of: .appearance), .invalid(raw: "sepia", fallback: .system))
    XCTAssertEqual(defaults.string(forKey: "appearance"), "sepia")
  }

  func testNonStringValueIsInvalid() {
    defaults.set(7, forKey: "appearance")
    let store = SettingsStore(defaults: defaults)
    XCTAssertEqual(store.reading(of: .appearance), .invalid(raw: "7", fallback: .system))
  }

  func testSetStoresRawString() {
    let store = SettingsStore(defaults: defaults)
    store.set(.dark, for: .appearance)
    XCTAssertEqual(defaults.string(forKey: "appearance"), "dark")
    XCTAssertEqual(store.value(of: .appearance), .dark)
  }

  /// Catches an observer that sees only the process's own writes. The write comes from a separate
  /// `defaults` process, as a user's `defaults write` does. It proves the store, not the window.
  func testObserverSeesWriteFromAnotherProcess() async throws {
    let store = SettingsStore(defaults: defaults)
    store.watch(.appearance)

    let changed = expectation(description: "observer ran")
    changed.assertForOverFulfill = false
    let observation = store.addObserver { changed.fulfill() }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
    process.arguments = ["write", testDefaults.suite, "appearance", "-string", "light"]
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)

    await fulfillment(of: [changed], timeout: 10)
    XCTAssertEqual(store.value(of: .appearance), .light)
    observation.cancel()
  }

  /// Catches `watch` stacking a second observer. Handlers must run once per change however often
  /// the key is watched, since each window and form watches the same key.
  func testWatchingTwiceNotifiesOncePerChange() async throws {
    let store = SettingsStore(defaults: defaults)
    store.watch(.appearance)
    store.watch(.appearance)

    var count = 0
    let first = expectation(description: "observer ran")
    first.assertForOverFulfill = false
    let observation = store.addObserver {
      count += 1
      first.fulfill()
    }

    testDefaults.reopen().set("light", forKey: "appearance")
    await fulfillment(of: [first], timeout: 10)
    try await Task.sleep(for: .milliseconds(300))

    XCTAssertEqual(count, 1)
    observation.cancel()
  }
}
