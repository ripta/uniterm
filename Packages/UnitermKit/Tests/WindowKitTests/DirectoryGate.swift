import Foundation

/// A directory check that holds a layout mid-preparation until the test opens it. It answers that
/// every directory exists.
///
/// Each check waits for its own `open()`, so a test can hold one layout after another. The test
/// learns that a check is waiting from `waitForCheck`, with no polling. Both waits have a deadline,
/// so a test whose layout never reaches its check fails instead of hanging.
final class DirectoryGate: @unchecked Sendable {
  private let opened = DispatchSemaphore(value: 0)
  private let entered = DispatchSemaphore(value: 0)

  var check: @Sendable (String) -> Bool {
    { [opened, entered] _ in
      entered.signal()
      _ = opened.wait(timeout: .now() + 10)
      return true
    }
  }

  /// Lets one waiting check, or the next one, through.
  func open() { opened.signal() }

  /// Waits until a check is waiting, and returns false once `timeout` seconds pass with none. The
  /// wait runs on a dispatch thread, so the main actor stays free to reach the check.
  func waitForCheck(timeout: TimeInterval = 10) async -> Bool {
    let entered = self.entered

    return await withCheckedContinuation { continuation in
      DispatchQueue.global().async {
        continuation.resume(returning: entered.wait(timeout: .now() + timeout) == .success)
      }
    }
  }
}
