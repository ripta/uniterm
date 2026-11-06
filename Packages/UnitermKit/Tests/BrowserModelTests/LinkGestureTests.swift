import XCTest

@testable import BrowserModel

/// The gate that tells a person's click from a page's script. It reads a mouse-up's time and the
/// time of the decision, and nothing else, so the bound and the one-shot rule test without a web
/// view.
final class LinkGestureTests: XCTestCase {
  private let start = Date(timeIntervalSince1970: 1_800_000_000)

  /// Catches a link decision that counts as followed with no mouse-up behind it, which is a page's
  /// own navigation.
  func testWithNoMouseUpNothingIsFollowed() {
    var gesture = LinkGesture()

    XCTAssertFalse(gesture.consume(at: start))
  }

  /// Catches a mouse-up that is not used, and one that can be used twice. The first decision
  /// takes it, and the next needs a click of its own.
  func testAMouseUpIsSpentByTheFirstDecision() {
    var gesture = LinkGesture()

    gesture.noteMouseUp(at: start)

    XCTAssertTrue(gesture.consume(at: start.addingTimeInterval(0.1)))
    XCTAssertFalse(gesture.consume(at: start.addingTimeInterval(0.2)))
  }

  /// Catches a bound that is off by one side. A decision exactly at the bound still counts, and
  /// one a moment later does not. A late decision also spends the note, so it cannot revive.
  func testTheBoundIsInclusiveAndAStaleDecisionSpendsTheNote() {
    var onTime = LinkGesture()
    onTime.noteMouseUp(at: start)

    XCTAssertTrue(onTime.consume(at: start.addingTimeInterval(LinkGesture.bound)))

    var late = LinkGesture()
    late.noteMouseUp(at: start)

    XCTAssertFalse(late.consume(at: start.addingTimeInterval(LinkGesture.bound + 0.001)))
    XCTAssertFalse(late.consume(at: start.addingTimeInterval(0.1)))
  }

  /// Catches a note from the future counting, as when the clock steps back after a click.
  func testAMouseUpFromTheFutureNeverCounts() {
    var gesture = LinkGesture()

    gesture.noteMouseUp(at: start.addingTimeInterval(10))

    XCTAssertFalse(gesture.consume(at: start))
  }

  /// Catches an older mouse-up winning over a newer one.
  func testTheLatestMouseUpReplacesTheEarlierOne() {
    var gesture = LinkGesture()

    gesture.noteMouseUp(at: start)
    gesture.noteMouseUp(at: start.addingTimeInterval(5))

    XCTAssertTrue(gesture.consume(at: start.addingTimeInterval(5.5)))
  }
}
