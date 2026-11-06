import XCTest

@testable import StatusKit

/// Each expected value is worked out by hand from the rules: coalescing on source, level, and text,
/// a history of 100 errors and 400 other records, and eviction from the most represented source.
final class StatusRetentionTests: XCTestCase {
  private func pane(_ id: UInt64, _ name: String = "p") -> StatusSource {
    .pane(id: id, name: name)
  }

  // MARK: Repeats

  /// Catches a repeat that takes a second turn on the bar, or that vanishes from the history.
  func testTheSameMessagePostedTwiceShowsOnceAndKeepsBothInTheHistory() {
    var queue = StatusQueue()
    queue.post(level: .info, source: pane(7, "zsh"), text: "done", at: 0)
    queue.post(level: .info, source: pane(7, "zsh"), text: "done", at: 0.2)

    XCTAssertEqual(queue.current?.message.text, "done")
    XCTAssertEqual(queue.pendingCount, 0)
    XCTAssertEqual(queue.history.map(\.id), [1, 2])
  }

  /// Catches a coalescing key that includes the title, or that ignores the pane ID or the level.
  func testEqualPaneIDsWithDifferentTitlesCoalesceButDifferentIDsAndLevelsDoNot() {
    var queue = StatusQueue()
    queue.post(level: .info, source: pane(7, "zsh"), text: "done", at: 0)
    queue.post(level: .info, source: pane(7, "renamed"), text: "done", at: 0.1)
    XCTAssertEqual(queue.pendingCount, 0, "a new title made a new message")

    queue.post(level: .info, source: pane(8, "zsh"), text: "done", at: 0.2)
    XCTAssertEqual(queue.pendingCount, 1, "another pane coalesced")

    queue.post(level: .warning, source: pane(7, "zsh"), text: "done", at: 0.3)
    XCTAssertEqual(queue.pendingCount, 2, "another level coalesced")
  }

  /// Catches a repeat that restarts the dwell, and a text that stays suppressed after it clears.
  ///
  /// The message is shown at 0 and repeated at 4.9. It still clears at 5. The same text posted at 6
  /// is a new load and shows again.
  func testARepeatNeverExtendsTheDwellAndANewLoadPostsAgain() {
    var queue = StatusQueue()
    queue.post(level: .warning, source: pane(1), text: "cut", at: 0)
    queue.post(level: .warning, source: pane(1), text: "cut", at: 4.9)

    XCTAssertEqual(queue.nextWake(), 5)
    XCTAssertTrue(queue.advance(at: 5))
    XCTAssertNil(queue.current)

    queue.post(level: .warning, source: pane(1), text: "cut", at: 6)
    XCTAssertEqual(queue.current?.message.text, "cut")
    XCTAssertEqual(queue.history.count, 3)
  }

  /// Catches a repeat of a message that is waiting or folded, which must coalesce too.
  ///
  /// 40 errors wait behind a shown message, so the backlog folds them into the newest. A repeat of
  /// the oldest one is inside the fold and takes no place.
  func testRepeatsCoalesceAgainstPendingAndFoldedMessages() {
    var queue = StatusQueue()
    queue.post(level: .info, source: pane(100), text: "shown", at: 0)
    queue.post(level: .info, source: pane(4), text: "i", at: 0.05)
    queue.post(level: .info, source: pane(4), text: "i", at: 0.06)
    XCTAssertEqual(queue.pendingCount, 1, "a waiting repeat took a place")

    for index in 0..<40 {
      queue.post(level: .error, source: pane(UInt64(index) + 1), text: "E\(index)", at: 0.1)
    }

    XCTAssertGreaterThan(queue.foldedStoredCount, 0)
    let waiting = queue.pendingCount

    queue.post(level: .error, source: pane(1), text: "E0", at: 0.2)
    XCTAssertEqual(queue.pendingCount, waiting, "a folded repeat took a place")
    XCTAssertEqual(queue.history.count, 44)
  }

  // MARK: Unseen

  /// Catches an acknowledgement that clears records the user was not shown.
  func testAcknowledgingClearsOnlyTheNamedRecords() {
    var queue = StatusQueue()
    let first = queue.post(level: .error, source: pane(1), text: "E1", at: 0)
    let second = queue.post(level: .error, source: pane(1), text: "E2", at: 0.1)

    XCTAssertEqual(queue.unseenErrorCount, 2)
    XCTAssertTrue(queue.acknowledge(ids: [second.id]))
    XCTAssertEqual(queue.unseenErrorCount, 1)
    XCTAssertTrue(queue.unseenIDs.contains(first.id))
    XCTAssertFalse(queue.acknowledge(ids: [second.id]), "a second acknowledgement changed nothing")
  }

  /// Catches a warning that raises the error signal, or a record that raises either.
  func testWarningsAndErrorsAreTrackedSeparately() {
    var queue = StatusQueue()
    queue.post(level: .warning, source: pane(1), text: "w", at: 0)
    XCTAssertTrue(queue.hasUnseenWarning)
    XCTAssertFalse(queue.hasUnseenError)

    queue.record(level: .error, source: pane(1), text: "quiet", at: 0)
    XCTAssertFalse(queue.hasUnseenError)

    queue.post(level: .error, source: pane(1), text: "E", at: 1)
    XCTAssertTrue(queue.hasUnseenError)
    XCTAssertTrue(queue.hasUnseenWarning)
  }

  // MARK: Retention

  /// Catches an error pool that grows past 100, or one that drops the newest.
  ///
  /// 101 errors from 101 panes tie on count, so the oldest goes. e1 through e100 remain.
  func testTheErrorPoolKeeps100() {
    var queue = StatusQueue()

    for index in 0..<101 {
      queue.post(level: .error, source: pane(UInt64(index) + 1), text: "e\(index)", at: 0)
    }

    XCTAssertEqual(queue.history.count, 100)
    XCTAssertEqual(queue.history.first?.text, "e1")
    XCTAssertEqual(queue.history.last?.text, "e100")
    XCTAssertEqual(queue.loss.errors, 1)
  }

  /// Catches an info flood from one pane that pushes another pane's error out.
  func testAnInfoFloodCannotEvictAnotherPanesError() {
    var queue = StatusQueue()
    queue.post(level: .error, source: pane(2, "other"), text: "keep me", at: 0)

    for index in 0..<900 {
      queue.post(level: .info, source: pane(1, "chatty"), text: "m\(index)", at: Double(index))
      queue.post(level: .warning, source: pane(1, "chatty"), text: "w\(index)", at: Double(index))
    }

    XCTAssertTrue(queue.history.contains { $0.text == "keep me" })
    XCTAssertEqual(queue.history.filter { $0.level != .error }.count, 400)
    XCTAssertEqual(queue.loss.errors, 0)
  }

  /// Catches an error flood that evicts from the wrong source.
  ///
  /// Pane 1 posts 80 errors, pane 2 posts 20, and pane 3 posts 1. The 101st leaves the pool, and it
  /// is pane 1's oldest, since pane 1 has the most rows.
  func testAnErrorFloodEvictsFromTheMostRepresentedSource() {
    var queue = StatusQueue()

    for index in 0..<80 {
      queue.post(level: .error, source: pane(1), text: "a\(index)", at: 0)
    }

    for index in 0..<20 {
      queue.post(level: .error, source: pane(2), text: "b\(index)", at: 0)
    }

    queue.post(level: .error, source: pane(3), text: "c", at: 0)

    XCTAssertEqual(queue.history.count, 100)
    XCTAssertFalse(queue.history.contains { $0.text == "a0" })
    XCTAssertTrue(queue.history.contains { $0.text == "a1" })
    XCTAssertEqual(queue.history.filter { $0.source.paneID == 2 }.count, 20)
    XCTAssertEqual(queue.history.filter { $0.source.paneID == 3 }.count, 1)
  }

  /// Catches a tie that evicts the newer source. Panes 1 and 2 hold 50 rows each, and pane 1
  /// posted first. A row from pane 3 pushes out pane 1's oldest.
  func testTiesEvictTheSourceWithTheOldestRecord() {
    var queue = StatusQueue()

    for index in 0..<50 {
      queue.post(level: .error, source: pane(1), text: "a\(index)", at: 0)
    }

    for index in 0..<50 {
      queue.post(level: .error, source: pane(2), text: "b\(index)", at: 0)
    }

    queue.post(level: .error, source: pane(3), text: "c", at: 0)

    XCTAssertEqual(queue.history.count, 100)
    XCTAssertFalse(queue.history.contains { $0.text == "a0" })
    XCTAssertTrue(queue.history.contains { $0.text == "b0" })
  }

  // MARK: Bounds

  /// Catches text and label storage that is not cut.
  func testLongTextAndLabelsAreCut() {
    var queue = StatusQueue()
    let long = String(repeating: "x", count: 10_000)
    let message = queue.post(level: .info, source: pane(1, long), text: long, at: 0)

    XCTAssertLessThanOrEqual(message.text.utf8.count, queue.policy.maximumTextBytes)
    XCTAssertTrue(message.text.hasSuffix("\u{2026}"))
    XCTAssertLessThanOrEqual(message.source.label.utf8.count, queue.policy.maximumLabelBytes)
  }

  /// Catches control characters and bidirectional overrides that reach a stored row.
  func testTextIsSanitized() {
    var queue = StatusQueue()
    let message = queue.post(
      level: .info, source: .uniterm, text: "a\u{1B}[31mred\u{202E}\nb", at: 0)

    XCTAssertEqual(message.text, "a [31mred b")
  }

  /// Catches a waiting backlog that grows without bound while the bar is busy.
  func testWaitingMessagesStayWithinTheirCountBound() {
    var queue = StatusQueue()
    queue.post(level: .info, source: pane(1), text: "shown", at: 0)

    for index in 0..<500 {
      queue.post(level: .info, source: pane(1), text: "m\(index)", at: 0.1)
    }

    XCTAssertLessThanOrEqual(queue.pendingCount, queue.policy.pendingLimit)
    XCTAssertEqual(queue.history.count, 400)
  }

  /// Catches a backlog that ignores its byte bound.
  func testWaitingMessagesStayWithinTheirByteBound() {
    var policy = StatusPolicy()
    policy.pendingBytes = 2_000

    var queue = StatusQueue(policy: policy)
    queue.post(level: .info, source: pane(1), text: "shown", at: 0)

    for index in 0..<20 {
      queue.post(
        level: .info, source: pane(1), text: String(repeating: "y", count: 400) + "\(index)",
        at: 0.1)
    }

    XCTAssertLessThan(queue.pendingCount, 6)
  }

  /// Catches a fold that keeps every error whole. 300 errors fold into one with at most 100 kept,
  /// and the count still says 299.
  func testFoldedErrorsAreBoundedButStillCounted() {
    var queue = StatusQueue()
    queue.post(level: .info, source: pane(1), text: "shown", at: 0)

    for index in 0..<300 {
      queue.post(level: .error, source: pane(UInt64(index) + 10), text: "e\(index)", at: 0.1)
    }

    queue.advance(at: 1.5)

    XCTAssertEqual(queue.current?.message.text, "e299")
    XCTAssertEqual(queue.current?.collapsedErrors, 299)
    XCTAssertLessThanOrEqual(queue.foldedStoredCount, queue.policy.foldedLimit)
  }

  /// Catches a pane close that requeues the survivors of its fold one by one, past the waiting
  /// bound. 33 errors from other panes sit folded in the closing pane's error. After the close they
  /// are folded again into one, and none is lost from the count.
  func testClosingAPaneKeepsTheWaitingBoundAndEveryOtherError() {
    var queue = StatusQueue()
    queue.post(level: .info, source: pane(1), text: "shown", at: 0)

    for index in 0..<33 {
      queue.post(level: .error, source: pane(UInt64(index) + 100), text: "b\(index)", at: 0.1)
    }

    for index in 0..<32 {
      queue.post(level: .error, source: pane(1), text: "a\(index)", at: 0.1)
    }

    XCTAssertEqual(queue.pendingCount, 1)
    XCTAssertTrue(queue.removePending(fromPane: 1))
    XCTAssertLessThanOrEqual(queue.pendingCount, queue.policy.pendingLimit)

    queue.advance(at: 1.5)

    XCTAssertEqual(queue.current?.message.text, "b32")
    XCTAssertEqual(queue.current?.collapsedErrors, 32)
  }

  /// Checks that the source index holds one entry for each source with a retained record. 1,000
  /// errors from 1,000 panes leave 100 entries, and 1,000 infos leave 400.
  func testTheSourceIndexStaysWithinTheRetainedRecords() {
    var queue = StatusQueue()

    for index in 0..<1_000 {
      queue.record(level: .error, source: pane(UInt64(index)), text: "e", at: 0)
      queue.record(level: .info, source: pane(UInt64(index) + 5_000), text: "i", at: 0)
    }

    XCTAssertEqual(queue.indexedSourceCount, 100 + 400)
    XCTAssertEqual(queue.history.count, 500)
  }

  /// Catches a pool that holds more bytes than its limit. 20 messages of 1,000 bytes cannot all
  /// fit in 4,096.
  func testRetainedBytesStayWithinTheLimit() {
    var policy = StatusPolicy()
    policy.otherHistoryBytes = 4_096

    var queue = StatusQueue(policy: policy)

    for index in 0..<20 {
      queue.record(
        level: .info, source: pane(1), text: String(repeating: "z", count: 1_000) + "\(index)",
        at: 0)
    }

    XCTAssertLessThanOrEqual(queue.historyBytes, 4_096)
    XCTAssertGreaterThan(queue.loss.others, 0)
    XCTAssertEqual(queue.history.last?.text.hasSuffix("19"), true)
  }

  // MARK: Loss

  /// Catches an eviction that acknowledges what it drops, or a summary nobody can clear.
  func testEvictionKeepsUnseenCountsUntilTheSummaryIsAcknowledged() {
    var policy = StatusPolicy()
    policy.errorHistoryLimit = 2
    policy.otherHistoryLimit = 1

    var queue = StatusQueue(policy: policy)

    for index in 0..<3 {
      queue.post(level: .error, source: pane(UInt64(index) + 1), text: "e\(index)", at: 0)
    }

    queue.post(level: .warning, source: pane(9), text: "w0", at: 0)
    queue.post(level: .warning, source: pane(9), text: "w1", at: 0)

    XCTAssertEqual(queue.history.count, 3)
    XCTAssertEqual(queue.unseenErrorCount, 3)
    XCTAssertEqual(queue.unseenWarningCount, 2)
    XCTAssertEqual(queue.loss.unseenErrors, 1)
    XCTAssertEqual(queue.loss.unseenWarnings, 1)

    queue.acknowledge(ids: queue.history.map(\.id))
    XCTAssertTrue(queue.hasUnseenError, "the dropped error was acknowledged by its neighbors")
    XCTAssertTrue(queue.hasUnseenWarning)

    XCTAssertTrue(queue.acknowledgeLoss())
    XCTAssertFalse(queue.hasUnseenError)
    XCTAssertFalse(queue.hasUnseenWarning)
    XCTAssertFalse(queue.acknowledgeLoss())
    XCTAssertEqual(queue.loss.errors, 1, "acknowledging forgot what was dropped")
  }

  /// Catches a summary with no readable words.
  func testTheLossSummaryReadsInFullSentences() {
    var loss = RetentionLoss()
    XCTAssertTrue(loss.isEmpty)

    loss.errors = 1
    loss.others = 12
    loss.unseenErrors = 1
    loss.unseenWarnings = 2

    XCTAssertEqual(
      loss.text,
      "The history dropped 1 error and 12 other messages to stay within its limits. "
        + "It held 1 unseen error and 2 unseen warnings.")
  }

  // MARK: Panes

  /// Catches a filter that keys on the title, and a pane list that loses a renamed pane.
  func testHistoryFiltersByStablePaneID() {
    var queue = StatusQueue()
    queue.post(level: .info, source: pane(1, "same"), text: "a", at: 0)
    queue.post(level: .info, source: pane(2, "same"), text: "b", at: 0)
    queue.post(level: .info, source: .uniterm, text: "host", at: 0)
    queue.post(level: .info, source: pane(1, "renamed"), text: "c", at: 0)

    XCTAssertEqual(queue.history(forPane: 1).map(\.text), ["a", "c"])
    XCTAssertEqual(queue.history(forPane: 2).map(\.text), ["b"])
    XCTAssertEqual(
      queue.historyPanes(), [HistoryPane(id: 1, name: "renamed"), HistoryPane(id: 2, name: "same")])
  }
}
