import DefaultsTestSupport
import XCTest

final class TestDefaultsTests: XCTestCase {
  /// Catches a discard that unlinks the file before `cfprefsd` writes the pending change, which
  /// leaves the file behind. The daemon writes about 20 seconds after a removal, and no cheaper
  /// check can observe that, so this one waits 25 seconds once for 30 suites.
  func testDiscardRightAfterWritesLeavesNoPreferenceFile() {
    var suites: [TestDefaults] = []

    for _ in 0..<30 {
      let test = TestDefaults()

      for index in 0..<5 {
        test.defaults.set(index, forKey: "key\(index)")
      }

      test.discard()
      suites.append(test)
    }

    Thread.sleep(forTimeInterval: 25)

    let left = suites.filter { FileManager.default.fileExists(atPath: $0.plistURL.path) }
    XCTAssertEqual(left.count, 0, "\(left.count) of \(suites.count) preference files remain")
  }

  func testDiscardClearsStoredValues() {
    let test = TestDefaults()
    test.defaults.set("value", forKey: "key")

    test.discard()

    XCTAssertNil(test.reopen().string(forKey: "key"))
    test.discard()
  }
}
