import AppKit
import AppletTestSupport
import StatusKit
import XCTest

@testable import AppletKit

@MainActor
final class AppletAlertsTests: XCTestCase {
  private func applet() -> PlaceholderApplet {
    PlaceholderApplet(
      keeping: AppletDescription(type: "x", version: 1, payload: .null), reason: "test")
  }

  // MARK: Attached

  /// Catches a delivery table that drifts from the settled restore rule. Each row is worked out
  /// from the rule: restore info goes to history, restore warnings raise attention only, errors
  /// and every other origin take a turn, and a pane that says it already stays history only.
  func testTheAttachedDeliveryFollowsOriginAndLevel() {
    let table: [(LoadOrigin, StatusLevel, AppletNotice.Delivery, StatusDelivery)] = [
      (.restore, .info, .message, .historyOnly),
      (.restore, .warning, .message, .attention),
      (.restore, .error, .message, .message),
      (.user, .info, .message, .message),
      (.user, .warning, .message, .message),
      (.reload, .info, .message, .message),
      (.reload, .warning, .message, .message),
      (.restore, .warning, .historyOnly, .historyOnly),
      (.user, .error, .historyOnly, .historyOnly),
    ]

    for (origin, level, own, expected) in table {
      let notice = AppletNotice(level, "x", delivery: own)

      XCTAssertEqual(
        AppletAlerts.delivery(of: notice, origin: origin), expected,
        "\(origin) \(level) \(own)")
    }
  }

  func testAnAttachedAlertIsDeliveredAtOnceAsItsOriginSays() {
    var alerts = AppletAlerts()
    let host = RecordingHost()
    let applet = applet()

    alerts.deliver(AppletNotice(.warning, "cut"), origin: .restore, from: applet, to: host)
    alerts.deliver(AppletNotice(.warning, "later"), origin: .user, from: applet, to: host)

    XCTAssertEqual(host.sent.map(\.delivery), [.attention, .message])
    XCTAssertEqual(alerts.heldCount, 0)
  }

  // MARK: Detached

  /// Catches a detached applet that shows an alert nobody can see, or one that waits to record it.
  /// The record is made when the event happens, with no signal and no turn.
  func testADetachedAlertIsRecordedAtOnceAndNothingIsShown() {
    var alerts = AppletAlerts()
    let host = RecordingHost()
    let applet = applet()

    alerts.detach()
    alerts.deliver(AppletNotice(.warning, "cut"), origin: .user, from: applet, to: host)

    XCTAssertEqual(host.sent.map(\.delivery), [.historyOnly])
    XCTAssertEqual(host.sent.map(\.text), ["cut"])
    XCTAssertEqual(alerts.heldCount, 1)
  }

  /// Catches a reattach that adds the history entries again. It presents each held alert through
  /// the record made at the event, and it keeps the delivery the origin chose.
  func testReattachPresentsHeldAlertsThroughTheirRecordsOnly() {
    var alerts = AppletAlerts()
    let host = RecordingHost()
    let applet = applet()

    alerts.detach()
    alerts.deliver(AppletNotice(.info, "moved"), origin: .user, from: applet, to: host)
    alerts.deliver(AppletNotice(.warning, "cut"), origin: .restore, from: applet, to: host)
    alerts.deliver(AppletNotice(.error, "lost"), origin: .restore, from: applet, to: host)

    XCTAssertEqual(host.admitted.count, 3)

    alerts.reattach(from: applet, to: host)

    XCTAssertEqual(host.admitted.count, 3, "reattach admitted a history entry")
    XCTAssertEqual(host.presented.map(\.text), ["moved", "cut", "lost"])
    XCTAssertEqual(host.presented.map(\.delivery), [.message, .attention, .message])
    XCTAssertEqual(host.presented.map(\.record), [1, 2, 3])
    XCTAssertEqual(alerts.heldCount, 0)
    XCTAssertFalse(alerts.isDetached)
  }

  /// Catches a restore-origin info that is held until reattach, or a notice the pane says itself
  /// that gets a turn on return. Neither would be shown even when attached.
  func testDetachedAlertsThatNeverPresentAreNotHeld() {
    var alerts = AppletAlerts()
    let host = RecordingHost()
    let applet = applet()

    alerts.detach()
    alerts.deliver(AppletNotice(.info, "moved"), origin: .restore, from: applet, to: host)
    alerts.deliver(
      AppletNotice(.warning, "empty", delivery: .historyOnly), origin: .user, from: applet,
      to: host)

    XCTAssertEqual(host.admitted.count, 2)
    XCTAssertEqual(alerts.heldCount, 0)

    alerts.reattach(from: applet, to: host)

    XCTAssertTrue(host.presented.isEmpty)
  }

  /// Catches a replaced load whose notices outlive it, and a replacement that drops more than it
  /// should. A new load drops the held notices of the old one. A held error stays, and so does an
  /// alert that no load produced. The dropped notice's record stays in the history.
  func testANewLoadDropsOnlyTheReplacedLoadsNonErrorNotices() {
    var alerts = AppletAlerts()
    let host = RecordingHost()
    let applet = applet()

    alerts.detach()
    alerts.deliver(AppletNotice(.warning, "cut"), origin: .user, from: applet, to: host)
    alerts.deliver(AppletNotice(.info, "moved"), origin: .user, from: applet, to: host)
    alerts.deliver(AppletNotice(.error, "lost work"), origin: .user, from: applet, to: host)
    alerts.deliver(.warning, "bell", from: applet, to: host)

    alerts.replaceLoad()

    XCTAssertEqual(alerts.heldCount, 2)

    alerts.reattach(from: applet, to: host)

    XCTAssertEqual(host.presented.map(\.text), ["lost work", "bell"])
    XCTAssertEqual(host.admitted.map(\.text), ["cut", "moved", "lost work", "bell"])
  }

  // MARK: The bound

  /// Catches an unbounded wait. Past the count limit, the oldest non-error alert goes, the loss is
  /// counted, and reattach says how many. Every alert is still in the history.
  func testTheWaitIsBoundedInCountAndOverflowIsCounted() {
    var alerts = AppletAlerts()
    let host = RecordingHost()
    let applet = applet()
    let total = AppletAlerts.heldLimit + 3

    alerts.detach()

    for index in 0..<total {
      alerts.deliver(AppletNotice(.warning, "w\(index)"), origin: .user, from: applet, to: host)
    }

    XCTAssertEqual(alerts.heldCount, AppletAlerts.heldLimit)
    XCTAssertEqual(alerts.overflowCount, 3)
    XCTAssertEqual(host.admitted.count, total, "the history keeps every alert")

    alerts.reattach(from: applet, to: host)

    XCTAssertEqual(host.admitted.count, total + 1, "only the count message is new")
    XCTAssertEqual(
      host.admitted.last?.text,
      "3 more alerts arrived while this pane was hidden. The history has them.")
    XCTAssertEqual(host.admitted.last?.level, .warning)
    XCTAssertEqual(host.admitted.last?.delivery, .message)
    XCTAssertEqual(host.presented.count, AppletAlerts.heldLimit)
    XCTAssertEqual(host.presented.first?.text, "w3")
    XCTAssertEqual(host.presented.last?.text, "w\(total - 1)")
  }

  /// Catches an error that goes before a warning when the wait overflows. The count message takes
  /// the most severe level that was lost.
  func testAnErrorOutlastsWarningsAndTheCountTakesTheMostSevereLevelLost() {
    var alerts = AppletAlerts()
    let host = RecordingHost()
    let applet = applet()

    alerts.detach()
    alerts.deliver(AppletNotice(.error, "lost work"), origin: .user, from: applet, to: host)

    for index in 0..<AppletAlerts.heldLimit {
      alerts.deliver(AppletNotice(.warning, "w\(index)"), origin: .user, from: applet, to: host)
    }

    alerts.reattach(from: applet, to: host)

    XCTAssertTrue(host.presented.contains { $0.text == "lost work" })
    XCTAssertEqual(host.admitted.last?.text.hasPrefix("1 more alert arrived"), true)
    XCTAssertEqual(host.admitted.last?.level, .warning)
  }

  /// Catches a byte bound that never binds. Long alerts cost their text, so a few fill the wait.
  func testTheWaitIsBoundedInBytes() {
    var alerts = AppletAlerts()
    let host = RecordingHost()
    let applet = applet()
    let long = String(repeating: "a", count: 2000)

    alerts.detach()

    for index in 0..<AppletAlerts.heldLimit {
      alerts.deliver(
        AppletNotice(.warning, "\(index)" + long), origin: .user, from: applet, to: host)
    }

    let capacity = AppletAlerts.heldBytes / (2000 + 64)

    XCTAssertEqual(alerts.heldCount, capacity)
    XCTAssertEqual(alerts.overflowCount, AppletAlerts.heldLimit - capacity)
    XCTAssertLessThan(capacity, AppletAlerts.heldLimit, "the byte bound must bind first here")
  }

  /// Catches a close that keeps what it held, or that drops the history. The records were made at
  /// the event, so the host holds them. The applet holds nothing.
  func testDiscardKeepsTheRecordsAndDropsThePresentation() {
    var alerts = AppletAlerts()
    let host = RecordingHost()
    let applet = applet()

    alerts.detach()
    alerts.deliver(AppletNotice(.warning, "cut"), origin: .user, from: applet, to: host)
    alerts.discard()

    XCTAssertEqual(alerts.heldCount, 0)
    XCTAssertEqual(host.admitted.map(\.text), ["cut"])

    alerts.reattach(from: applet, to: host)

    XCTAssertTrue(host.presented.isEmpty)
  }
}
