import XCTest

@testable import StatusKit

final class StderrIngressTests: XCTestCase {
  /// Catches an ingress that grows without bound or that loses a line
  /// without counting it.
  ///
  /// Four threads offer 40,000 lines each while the main thread drains. Every batch stays within
  /// the bounds. Each line is either counted in a batch or counted as dropped, so the totals match.
  /// The producers are dedicated threads. Other test classes can leave the shared dispatch pool
  /// without a free worker, and a producer queued there would never run.
  func testAFloodStaysBoundedAndNeverBlocksTheDrainer() {
    let ingress = StderrIngress(maximumLines: 64, maximumBytes: 16 * 1024, maximumLineBytes: 512)
    let group = DispatchGroup()
    let perThread = 40_000

    for producer in 0..<4 {
      group.enter()

      let thread = Thread {
        for index in 0..<perThread {
          ingress.offer("thread \(producer) line \(index % 7)\n")
        }

        group.leave()
      }

      thread.start()
    }

    var counted = 0
    var dropped = 0
    var finished = false

    while !finished {
      let batch = ingress.drain()

      XCTAssertLessThanOrEqual(batch.lines.count, 64)
      XCTAssertLessThanOrEqual(batch.lines.reduce(0) { $0 + $1.text.utf8.count }, 16 * 1024)

      counted += batch.lines.reduce(0) { $0 + $1.count }
      dropped += batch.dropped

      finished = group.wait(timeout: .now() + .milliseconds(1)) == .success
    }

    let last = ingress.drain()
    counted += last.lines.reduce(0) { $0 + $1.count }
    dropped += last.dropped

    XCTAssertEqual(counted + dropped, 4 * perThread)
  }

  /// Catches a chunk that is processed in full under the lock. A chunk of 100,000 lines is cut at
  /// the ingress's per-chunk bound, and every line past it is counted as dropped.
  func testAHugeChunkIsCutAndTheRestCounted() {
    let ingress = StderrIngress()
    let total = 100_000

    ingress.offer(String(repeating: "x\n", count: total))
    let batch = ingress.drain()

    XCTAssertGreaterThan(batch.dropped, 0)
    XCTAssertEqual(batch.lines.reduce(0) { $0 + $1.count } + batch.dropped, total)
  }

  /// Catches an offer that cannot tell the caller when to schedule a hop.
  func testOfferSaysWhenTheBufferWasEmpty() {
    let ingress = StderrIngress()

    XCTAssertTrue(ingress.offer("first"))
    XCTAssertFalse(ingress.offer("second"))
    XCTAssertEqual(ingress.drain().lines.map(\.text), ["first", "second"])
    XCTAssertTrue(ingress.offer("third"))
  }

  /// Catches identical neighbors that take a line each.
  func testIdenticalNeighborsCoalesceIntoACount() {
    let ingress = StderrIngress()
    ingress.offer("warn\nwarn\nwarn\nother\nwarn\n")

    let batch = ingress.drain()

    XCTAssertEqual(batch.lines.map(\.text), ["warn", "other", "warn"])
    XCTAssertEqual(batch.lines.map(\.count), [3, 1, 1])
  }

  /// Catches a line that reaches the buffer unsanitized or uncut.
  func testLinesAreSanitizedAndCut() {
    let ingress = StderrIngress(maximumLineBytes: 16)
    ingress.offer("ok\u{1B}[0m\n" + String(repeating: "q", count: 100))

    let lines = ingress.drain().lines.map(\.text)

    XCTAssertEqual(lines[0], "ok [0m")
    XCTAssertLessThanOrEqual(lines[1].utf8.count, 16)
  }
}

@MainActor
final class StatusProducerTests: XCTestCase {
  private final class Clock: StatusClock, @unchecked Sendable {
    var now: TimeInterval = 0
  }

  private func makeCenter(limit: Int? = nil) -> StatusCenter {
    var policy = StatusPolicy()
    if let limit { policy.producerLimit = limit }

    return StatusCenter(policy: policy, clock: Clock(), scheduler: { _, _ in {} })
  }

  /// Catches raw stderr that takes a level from its words, takes a turn on the bar, or raises a
  /// signal. Every line is info, in the history only.
  func testRawStderrIsInfoWhateverItSays() throws {
    let center = makeCenter()
    let producer = try XCTUnwrap(center.issueProducer(kind: .script, name: "driver"))
    let ingress = StderrIngress()
    ingress.offer("FATAL: error, panic, failed\ncritical error\n")

    producer.record(stderr: ingress.drain())

    XCTAssertEqual(center.history.map(\.level), [.info, .info])
    XCTAssertNil(center.display)
    XCTAssertFalse(center.hasUnseenError)
    XCTAssertFalse(center.hasUnseenWarning)
  }

  /// Catches a coalesced count and a drop count that never reach the history.
  func testCoalescedAndDroppedLinesAreReadable() throws {
    let center = makeCenter()
    let producer = try XCTUnwrap(center.issueProducer(kind: .script, name: "driver"))
    let batch = StderrBatch(lines: [.init(text: "again", count: 3)], dropped: 2)

    producer.record(stderr: batch)

    XCTAssertEqual(
      center.history.map(\.text),
      ["again (\u{00D7}3)", "2 lines of output did not fit and were dropped."])
  }

  /// Catches a typed failure that loses its semantic level.
  func testTypedDriverFailuresKeepTheirSeverity() throws {
    let center = makeCenter()
    let producer = try XCTUnwrap(center.issueProducer(kind: .script, name: "driver"))

    producer.post(failure: .contentUnavailable, text: "the view is unavailable")
    producer.post(failure: .workLost, text: "unsaved edits were lost")

    XCTAssertEqual(center.history.map(\.level), [.warning, .error])
    XCTAssertTrue(center.hasUnseenError)
  }

  /// Catches two producers with one name that share an identity, so one's text hides the other's.
  func testSameNameProducersKeepDistinctIdentities() throws {
    let center = makeCenter()
    let first = try XCTUnwrap(center.issueProducer(kind: .applet, name: "git"))
    let second = try XCTUnwrap(center.issueProducer(kind: .applet, name: "git"))

    first.post(level: .info, text: "dirty")
    second.post(level: .info, text: "dirty")

    XCTAssertNotEqual(first.source.key, second.source.key)
    XCTAssertEqual(center.history.count, 2)
    XCTAssertEqual(center.queue.pendingCount, 1, "the second did not take its own turn")
  }

  /// Catches a caller that names a source the center never issued.
  func testAnUnissuedIdentityCannotPost() throws {
    let center = makeCenter()

    XCTAssertFalse(center.post(level: .error, source: .applet(id: 99, name: "x"), text: "forged"))
    XCTAssertFalse(center.record(level: .error, source: .script(id: 1, name: "x"), text: "forged"))
    XCTAssertTrue(center.history.isEmpty)
  }

  /// Catches a retired producer that still posts, or whose records vanish. The bound frees a slot
  /// on retirement.
  func testRetiredProducersStopPostingAndFreeTheirSlot() throws {
    let center = makeCenter(limit: 1)
    let first = try XCTUnwrap(center.issueProducer(kind: .applet, name: "a"))
    XCTAssertNil(center.issueProducer(kind: .applet, name: "b"))

    first.post(level: .info, text: "before")
    first.retire()
    first.post(level: .info, text: "after")

    XCTAssertEqual(center.history.map(\.text), ["before"])

    let next = try XCTUnwrap(center.issueProducer(kind: .applet, name: "b"))
    XCTAssertNotEqual(next.source.key, first.source.key)
  }

  /// Catches a producer dropped without `retire` that keeps its slot, so after 64 such producers
  /// the window issues no more.
  func testADroppedProducerFreesItsSlot() throws {
    let center = makeCenter(limit: 1)

    do {
      let dropped = try XCTUnwrap(center.issueProducer(kind: .applet, name: "a"))
      dropped.post(level: .info, text: "kept")
    }

    XCTAssertNotNil(center.issueProducer(kind: .applet, name: "b"))
    XCTAssertEqual(center.history.map(\.text), ["kept"])
  }

  /// Catches an identity checked by number alone. A script source that borrows an applet's ID is
  /// refused, and so is the applet source that borrows a script's.
  func testAForgedKindIsRefusedEvenWithAnIssuedID() throws {
    let center = makeCenter()
    let applet = try XCTUnwrap(center.issueProducer(kind: .applet, name: "a"))
    let script = try XCTUnwrap(center.issueProducer(kind: .script, name: "s"))
    let key = applet.source.key
    let scriptKey = script.source.key

    guard case .applet(let appletID) = key, case .script(let scriptID) = scriptKey else {
      return XCTFail("unexpected identity kinds")
    }

    XCTAssertFalse(
      center.post(level: .error, source: .script(id: appletID, name: "x"), text: "forged"))
    XCTAssertFalse(
      center.record(level: .error, source: .applet(id: scriptID, name: "x"), text: "forged"))
    XCTAssertTrue(center.history.isEmpty)
  }

  /// Catches a stderr batch that refreshes observers once for each line. A panel that is open
  /// rebuilds its rows on each refresh, so a full batch must cost one.
  func testAStderrBatchReachesObserversOnce() throws {
    let center = makeCenter()
    let producer = try XCTUnwrap(center.issueProducer(kind: .script, name: "driver"))
    var rounds = 0
    center.addObserver { rounds += 1 }
    let batch = StderrBatch(
      lines: [.init(text: "a", count: 1), .init(text: "b", count: 2), .init(text: "c", count: 1)],
      dropped: 4)

    producer.record(stderr: batch)

    XCTAssertEqual(rounds, 1)
    XCTAssertEqual(center.history.count, 4)
  }
}
