import AppletKit
import XCTest

final class AppletNoticesTests: XCTestCase {
  /// Catches a notice that posts again each time its count grows. Two notices with one key are one
  /// notice, whatever their text says. A reset forgets the key, so a new load posts again.
  func testANoticeWithAKeyPostsOnceWhileItsTextChanges() {
    var notices = AppletNotices()

    let first = notices.unposted([AppletNotice(.warning, "1 row cut", key: "cut")])
    let second = notices.unposted([AppletNotice(.warning, "2 rows cut", key: "cut")])

    XCTAssertEqual(first.map(\.text), ["1 row cut"])
    XCTAssertTrue(second.isEmpty)

    notices.reset()

    XCTAssertEqual(
      notices.unposted([AppletNotice(.warning, "2 rows cut", key: "cut")]).map(\.text),
      ["2 rows cut"])
  }

  /// Catches a notice that doubles when its delivery changes between refreshes. A failure the
  /// pane first leaves to the bar, and later explains itself, is still the same notice.
  func testTheDeliveryIsNotPartOfTheNoticesIdentity() {
    var notices = AppletNotices()

    let bar = AppletNotice(.warning, "The file is missing.")
    let history = AppletNotice(.warning, "The file is missing.", delivery: .historyOnly)

    XCTAssertEqual(notices.unposted([bar]).count, 1)
    XCTAssertTrue(notices.unposted([history]).isEmpty)
  }

  /// Catches a key that defaults to something other than the text. Without a key, two notices are
  /// the same exactly when their text is.
  func testWithoutAKeyTheTextIsTheIdentity() {
    var notices = AppletNotices()

    XCTAssertEqual(notices.unposted([AppletNotice(.info, "a"), AppletNotice(.info, "a")]).count, 1)
    XCTAssertEqual(notices.unposted([AppletNotice(.info, "b")]).count, 1)
  }
}
