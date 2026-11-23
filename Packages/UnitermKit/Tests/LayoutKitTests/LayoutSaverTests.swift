import Foundation
import PaneModel
import XCTest

@testable import LayoutKit

@MainActor
private final class ManualScheduler {
  private(set) var pending: [(delay: TimeInterval, action: @MainActor () -> Void, id: Int)] = []
  private var next = 0
  private(set) var cancelled = 0

  func schedule(_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void)
    -> @MainActor () -> Void
  {
    next += 1
    let id = next
    pending.append((delay, action, id))

    return { [self] in
      if pending.contains(where: { $0.id == id }) { cancelled += 1 }

      pending.removeAll { $0.id == id }
    }
  }

  func fire() {
    guard let last = pending.last else { return }

    pending.removeAll { $0.id == last.id }
    last.action()
  }
}

@MainActor
final class LayoutSaverTests: XCTestCase {
  private struct Boom: Error, CustomStringConvertible {
    let description: String
  }

  private func make(
    scheduler: ManualScheduler, writes: Counter, failures: Counter, fails: Bool = false
  ) -> LayoutSaver {
    LayoutSaver(
      debounce: 1, scheduler: scheduler.schedule,
      snapshot: { SavedLayout(windows: []) },
      write: { _ in
        writes.increment()

        if fails { throw Boom(description: "disk full") }
      },
      onFailure: { _ in failures.value += 1 })
  }

  /// Catches a debounce that writes on every change. Five changes make one debounce wait, plus
  /// the one maximum wait, and one write once the debounce fires.
  func testABurstOfChangesWritesOnce() {
    let scheduler = ManualScheduler()
    let writes = Counter()
    let saver = make(scheduler: scheduler, writes: writes, failures: Counter())
    saver.enable()

    for _ in 1...5 { saver.layoutDidChange() }

    XCTAssertEqual(scheduler.pending.map(\.delay).sorted(), [1, 10])
    XCTAssertEqual(writes.value, 0)

    scheduler.fire()
    saver.waitForWrites()
    XCTAssertEqual(writes.value, 1)
    XCTAssertTrue(scheduler.pending.isEmpty, "a save drops the maximum wait too")
  }

  /// Catches debounce starvation. Changes that never stop, such as a title that animates, keep
  /// restarting the debounce, and it never fires. The maximum wait started by the first change
  /// must still write, and the next change after it starts a new wait.
  func testAnEndlessStreamOfChangesStillWritesWithinTheMaximumWait() {
    let scheduler = ManualScheduler()
    let writes = Counter()
    let saver = make(scheduler: scheduler, writes: writes, failures: Counter())
    saver.enable()

    for _ in 1...200 { saver.layoutDidChange() }

    XCTAssertEqual(writes.value, 0, "the debounce never had a quiet moment")

    let deadline = scheduler.pending.first { $0.delay == 10 }
    XCTAssertNotNil(deadline, "no maximum wait was scheduled")
    deadline?.action()
    saver.waitForWrites()

    XCTAssertEqual(writes.value, 1)
    XCTAssertTrue(scheduler.pending.isEmpty)

    saver.layoutDidChange()
    XCTAssertEqual(scheduler.pending.map(\.delay).sorted(), [1, 10])
  }

  /// Catches a quit that waits for the debounce. The change and the quit come at once, with the
  /// wait still pending. The save must happen anyway, and the pending wait must go.
  func testASaveNowCoversAPendingChange() {
    let scheduler = ManualScheduler()
    let writes = Counter()
    let saver = make(scheduler: scheduler, writes: writes, failures: Counter())
    saver.enable()

    saver.layoutDidChange()
    saver.saveNow()
    saver.waitForWrites()

    XCTAssertEqual(writes.value, 1)
    XCTAssertTrue(scheduler.pending.isEmpty)
  }

  /// Catches saves during a launch. Nothing is written until the caller enables saving.
  func testNothingIsWrittenWhileSavingIsOff() {
    let scheduler = ManualScheduler()
    let writes = Counter()
    let saver = make(scheduler: scheduler, writes: writes, failures: Counter())

    saver.layoutDidChange()
    saver.saveNow()

    XCTAssertEqual(writes.value, 0)
    XCTAssertTrue(scheduler.pending.isEmpty)

    saver.enable()
    saver.layoutDidChange()
    saver.disable()

    XCTAssertTrue(scheduler.pending.isEmpty, "disabling drops the pending save")
    saver.saveNow()
    XCTAssertEqual(writes.value, 0)
  }

  /// A write that keeps failing the same way is reported once, not once per change.
  func testARepeatedFailureIsReportedOnce() {
    let scheduler = ManualScheduler()
    let writes = Counter()
    let failures = Counter()
    let saver = make(scheduler: scheduler, writes: writes, failures: failures, fails: true)
    saver.enable()

    saver.saveNow()
    saver.waitForWrites()
    saver.saveNow()
    saver.waitForWrites()

    XCTAssertEqual(writes.value, 2)
    XCTAssertEqual(failures.value, 1)
  }

  /// Catches a quit that returns while the last write is still running. The write is held open,
  /// and `waitForWrites` must not return until it ends.
  func testWaitForWritesBlocksUntilTheWriteEnds() {
    let log = WriteLog()
    let release = DispatchSemaphore(value: 0)
    let ended = Counter()

    let saver = LayoutSaver(
      debounce: 1, scheduler: ManualScheduler().schedule,
      snapshot: { SavedLayout(windows: []) },
      write: { _ in
        log.record(onMainThread: Thread.isMainThread)
        _ = release.wait(timeout: .now() + 10)
        ended.increment()
      },
      onFailure: { _ in })
    saver.enable()

    saver.saveNow()
    XCTAssertTrue(log.waitForWrite(timeout: 10), "the write never started")

    DispatchQueue.global().async { release.signal() }
    saver.waitForWrites()

    XCTAssertEqual(ended.value, 1, "waitForWrites returned before the write ended")
  }

  /// Catches a pile of writes behind a slow one, or a newest layout that is dropped. Three saves
  /// arrive while the first write is held open. The first and only the newest of the rest may run.
  func testOnlyTheNewestLayoutWaitsBehindAWriteInFlight() {
    let log = WriteLog()
    let release = DispatchSemaphore(value: 0)
    let titles = TitleLog()
    let next = Counter()

    let saver = LayoutSaver(
      debounce: 1, scheduler: ManualScheduler().schedule,
      snapshot: {
        next.increment()
        return SavedLayout(windows: [window(tree: pane(UInt64(next.value)))])
      },
      write: { layout in
        titles.record(layout.windows[0].tree.paneIDs[0].rawValue)
        log.record(onMainThread: Thread.isMainThread)
        _ = release.wait(timeout: .now() + 10)
      },
      onFailure: { _ in })
    saver.enable()

    saver.saveNow()
    XCTAssertTrue(log.waitForWrite(timeout: 10), "the first write never started")

    saver.saveNow()
    saver.saveNow()
    saver.saveNow()

    release.signal()
    release.signal()
    release.signal()
    saver.waitForWrites()

    XCTAssertEqual(titles.values, [1, 4])
  }

  /// Catches a layout written after saving was turned off. A second save waits behind a write held
  /// open. Turning saving off must drop it, while the write already running still finishes.
  func testDisablingDropsTheLayoutWaitingBehindAWrite() {
    let log = WriteLog()
    let release = DispatchSemaphore(value: 0)
    let titles = TitleLog()
    let next = Counter()

    let saver = LayoutSaver(
      debounce: 1, scheduler: ManualScheduler().schedule,
      snapshot: {
        next.increment()
        return SavedLayout(windows: [window(tree: pane(UInt64(next.value)))])
      },
      write: { layout in
        titles.record(layout.windows[0].tree.paneIDs[0].rawValue)
        log.record(onMainThread: Thread.isMainThread)
        _ = release.wait(timeout: .now() + 10)
      },
      onFailure: { _ in })
    saver.enable()

    saver.saveNow()
    XCTAssertTrue(log.waitForWrite(timeout: 10), "the first write never started")

    saver.saveNow()
    saver.disable()

    release.signal()
    release.signal()
    saver.waitForWrites()

    XCTAssertEqual(titles.values, [1])
  }

  /// Catches a save that encodes and writes on the main thread. A layout of tens of thousands of
  /// tabs would stall every window for each debounced change. It cannot show the stall itself,
  /// only that the write runs elsewhere.
  func testTheWriteRunsOffTheMainThread() {
    let scheduler = ManualScheduler()
    let log = WriteLog()

    let saver = LayoutSaver(
      debounce: 1, scheduler: scheduler.schedule,
      snapshot: { SavedLayout(windows: []) },
      write: { _ in log.record(onMainThread: Thread.isMainThread) },
      onFailure: { _ in })
    saver.enable()

    saver.layoutDidChange()
    scheduler.fire()

    XCTAssertTrue(log.waitForWrite(timeout: 10), "no write happened")
    XCTAssertEqual(log.onMainThread, [false])
  }
}

final class TitleLog: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [UInt64] = []

  var values: [UInt64] {
    lock.lock()
    defer { lock.unlock() }

    return recorded
  }

  func record(_ value: UInt64) {
    lock.lock()
    recorded.append(value)
    lock.unlock()
  }
}

/// Records where each write ran. A semaphore lets the test wait without spinning, whether the
/// write ran before the wait or after it.
final class WriteLog: @unchecked Sendable {
  private let lock = NSLock()
  private let signal = DispatchSemaphore(value: 0)
  private var threads: [Bool] = []

  var onMainThread: [Bool] {
    lock.lock()
    defer { lock.unlock() }

    return threads
  }

  func record(onMainThread: Bool) {
    lock.lock()
    threads.append(onMainThread)
    lock.unlock()

    signal.signal()
  }

  func waitForWrite(timeout: TimeInterval) -> Bool {
    signal.wait(timeout: .now() + timeout) == .success
  }
}

/// A count that a write thread and the test both touch.
final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var value: Int {
    get {
      lock.lock()
      defer { lock.unlock() }

      return count
    }
    set {
      lock.lock()
      count = newValue
      lock.unlock()
    }
  }

  func increment() {
    lock.lock()
    count += 1
    lock.unlock()
  }
}
