import XCTest

/// How often a UI test wait checks its condition again.
///
/// XCTest's own waits, `waitForExistence(timeout:)` and `XCTNSPredicateExpectation`, check a
/// condition once a second and check first after a second. So each wait cost about a second even
/// when the element was already there. On CI that came to about 550 seconds of a 32-minute UI run.
/// These waits check at once, then every quarter second.
let uiTestPollInterval: TimeInterval = 0.25

/// Checks `condition` at once, then every `uiTestPollInterval`, until it holds or `timeout`
/// passes. Returns whether it held.
@MainActor
func pollUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
  let deadline = Date().addingTimeInterval(timeout)

  while !condition() {
    guard Date() < deadline else { return false }

    Thread.sleep(forTimeInterval: uiTestPollInterval)
  }

  return true
}

extension XCUIElement {
  /// Waits up to `timeout` for the element to exist. It stands in for `waitForExistence(timeout:)`
  /// without that call's one-second first check.
  func appears(timeout: TimeInterval) -> Bool {
    pollUntil(timeout: timeout) { exists }
  }

  /// Waits up to `timeout` for the element to stop existing.
  func disappears(timeout: TimeInterval) -> Bool {
    pollUntil(timeout: timeout) { !exists }
  }
}
