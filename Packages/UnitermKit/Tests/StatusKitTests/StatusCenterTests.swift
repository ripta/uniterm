import XCTest

@testable import StatusKit

private final class ManualClock: StatusClock, @unchecked Sendable {
  var now: TimeInterval = 0
}

/// Holds the wakeups that a center asks for, so a test fires them by hand.
@MainActor
private final class ManualScheduler {
  var scheduled: [(delay: TimeInterval, action: @MainActor () -> Void, id: Int)] = []
  var cancelled: Set<Int> = []
  private var counter = 0

  func schedule(_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void)
    -> @MainActor () ->
    Void
  {
    counter += 1
    let id = counter
    scheduled.append((delay, action, id))
    return { [weak self] in self?.cancelled.insert(id) }
  }

  func fireLast() {
    guard let last = scheduled.last, !cancelled.contains(last.id) else { return }

    last.action()
  }
}

@MainActor
final class StatusCenterTests: XCTestCase {
  /// Catches a record that the center keeps from its observers. The history panel redraws from
  /// the observers, so a record that skips them would show up only after the next post.
  func testARecordTellsObserversAndLeavesTheBarAlone() {
    let center = StatusCenter(clock: ManualClock(), scheduler: ManualScheduler().schedule)
    var calls = 0
    center.addObserver { calls += 1 }

    center.record(level: .warning, source: .uniterm, text: "kept")

    XCTAssertEqual(calls, 1)
    XCTAssertEqual(center.history.map(\.text), ["kept"])
    XCTAssertNil(center.display)
    XCTAssertFalse(center.hasUnseenError)
  }

  /// Catches a center that never wakes the model, so an info message stays on the bar forever.
  func testWakeClearsInfoAtTheIdleTimeout() {
    let clock = ManualClock()
    let scheduler = ManualScheduler()
    let center = StatusCenter(clock: clock, scheduler: scheduler.schedule)

    center.post(level: .info, source: .uniterm, text: "hello")

    XCTAssertEqual(center.display?.message.text, "hello")
    XCTAssertEqual(scheduler.scheduled.last?.delay, 5)

    clock.now = 5
    scheduler.fireLast()

    XCTAssertNil(center.display)
  }

  /// Catches a stale wakeup. Posting again cancels the earlier wakeup and asks for a new one.
  func testPostReplacesThePendingWakeup() {
    let clock = ManualClock()
    let scheduler = ManualScheduler()
    let center = StatusCenter(clock: clock, scheduler: scheduler.schedule)

    center.post(level: .info, source: .uniterm, text: "a")
    center.post(level: .info, source: .uniterm, text: "b")

    XCTAssertEqual(scheduler.cancelled.count, 1)
    XCTAssertEqual(scheduler.scheduled.last?.delay, 1.5)

    clock.now = 1.5
    scheduler.fireLast()

    XCTAssertEqual(center.display?.message.text, "b")
  }

  /// Catches a pane close that edits the queue and leaves the old wakeup in place.
  ///
  /// The wakeup is at 1.5 while b waits. With b gone it moves to a's idle timeout at 5.
  func testPaneClosedReschedulesTheWakeupAndNotifies() {
    let clock = ManualClock()
    let scheduler = ManualScheduler()
    let center = StatusCenter(clock: clock, scheduler: scheduler.schedule)
    var count = 0
    center.addObserver { count += 1 }

    center.post(level: .info, source: .uniterm, text: "a")
    center.post(level: .info, source: .pane(id: 3, name: "zsh"), text: "b")
    XCTAssertEqual(scheduler.scheduled.last?.delay, 1.5)
    XCTAssertEqual(count, 2)

    center.paneClosed(id: 3)

    XCTAssertEqual(count, 3)
    XCTAssertEqual(scheduler.scheduled.last?.delay, 5)
    XCTAssertEqual(center.history.map(\.text), ["a", "b"])

    center.paneClosed(id: 3)
    XCTAssertEqual(count, 3, "a close with nothing queued is not a change")
  }

  func testObserversHearEveryChange() {
    let clock = ManualClock()
    let scheduler = ManualScheduler()
    let center = StatusCenter(clock: clock, scheduler: scheduler.schedule)
    var count = 0
    center.addObserver { count += 1 }

    center.post(level: .error, source: .uniterm, text: "E")
    XCTAssertTrue(center.hasUnseenError)
    center.markHistorySeen()
    center.dismissCurrent()

    XCTAssertEqual(count, 3)
    XCTAssertFalse(center.hasUnseenError)
    XCTAssertNil(center.display)
  }
}
