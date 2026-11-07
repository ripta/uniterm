import XCTest

@testable import ImageViewerModel

final class SchedulerAndBudgetTests: XCTestCase {
  private func request(_ id: UInt32, _ kind: DecodeRequest.Kind = .still, frame: Int = 0)
    -> DecodeRequest
  {
    DecodeRequest(id: id, source: 1, maxPixel: 100, frame: frame, kind: kind)
  }

  /// Catches a scheduler that sends two decodes at once, or queues more than one. One is in flight,
  /// one waits, and a newer request replaces the waiting one.
  func testLatestWinsWithOneInFlightAndOneWaiting() {
    var scheduler = RequestScheduler()

    XCTAssertEqual(scheduler.submit(request(1)), request(1))
    XCTAssertNil(scheduler.submit(request(2)))
    XCTAssertNil(scheduler.submit(request(3)))
    XCTAssertEqual(scheduler.inFlight, request(1))
    XCTAssertEqual(scheduler.pending, request(3))

    XCTAssertEqual(scheduler.finish(), request(3))
    XCTAssertNil(scheduler.pending)
    XCTAssertNil(scheduler.finish())
    XCTAssertTrue(scheduler.isIdle)
  }

  /// Catches an animation starving a step. A frame request never replaces a waiting still, and a
  /// still replaces a waiting frame.
  func testAFrameRequestYieldsToAStill() {
    var scheduler = RequestScheduler()

    _ = scheduler.submit(request(1))
    XCTAssertNil(scheduler.submit(request(2, .frame, frame: 1)))
    XCTAssertEqual(scheduler.pending, request(2, .frame, frame: 1))

    XCTAssertNil(scheduler.submit(request(3)))
    XCTAssertEqual(scheduler.pending, request(3))

    XCTAssertNil(scheduler.submit(request(4, .frame, frame: 2)))
    XCTAssertEqual(scheduler.pending, request(3))
  }

  /// Catches a prefetch that takes a slot a step needs. It takes the idle slot, waits behind a decode
  /// in flight when nothing else waits, and is dropped when another request already waits.
  func testAPrefetchTakesTheIdleSlotAndYieldsToEveryOtherRequest() {
    var scheduler = RequestScheduler()

    XCTAssertEqual(scheduler.submit(request(1, .prefetch)), request(1, .prefetch))
    XCTAssertNil(scheduler.submit(request(2, .prefetch)))
    XCTAssertEqual(scheduler.pending, request(2, .prefetch))

    XCTAssertNil(scheduler.submit(request(3)), "a step replaces the waiting prefetch")
    XCTAssertEqual(scheduler.pending, request(3))
    XCTAssertEqual(scheduler.inFlight, request(1, .prefetch), "the one decoding runs to completion")

    XCTAssertNil(scheduler.submit(request(4, .prefetch)), "a waiting step is not displaced")
    XCTAssertEqual(scheduler.pending, request(3))
    XCTAssertEqual(scheduler.finish(), request(3))
  }

  /// Catches a pane zoomed past fit prefetching. The gate refuses new prefetches and drops one that
  /// waits, while leaving other requests alone.
  func testAPaneZoomedPastFitNeverPrefetches() {
    var scheduler = RequestScheduler()

    _ = scheduler.submit(request(1))
    XCTAssertNil(scheduler.submit(request(2, .prefetch)))
    XCTAssertEqual(scheduler.pending?.kind, .prefetch)

    scheduler.isZoomedPastFit = true

    XCTAssertNil(scheduler.pending)
    XCTAssertNil(scheduler.submit(request(3, .prefetch)))
    XCTAssertNil(scheduler.pending)
    XCTAssertNil(scheduler.submit(request(4)))
    XCTAssertEqual(scheduler.pending, request(4))

    scheduler.reset()
    scheduler.isZoomedPastFit = true

    XCTAssertNil(scheduler.submit(request(5, .prefetch)), "an idle zoomed pane still refuses")
    XCTAssertTrue(scheduler.isIdle)
  }

  /// Catches a reset that leaves a request behind, as when a helper dies with one in flight.
  func testResetForgetsBothRequests() {
    var scheduler = RequestScheduler()

    _ = scheduler.submit(request(1))
    _ = scheduler.submit(request(2))
    scheduler.reset()

    XCTAssertTrue(scheduler.isIdle)
    XCTAssertEqual(scheduler.submit(request(3)), request(3))
  }

  /// Catches a helper budget that refuses a pane its floor, or that lets the others' memory crowd
  /// a pane out. A request inside the floor is always admitted, and the budget never counts the
  /// asking pane's own footprint twice.
  func testTheHelperBudgetAdmitsInsideTheFloorAndRefusesPastTheLimit() {
    let budget = ImageHelperBudget(limit: 1000, floor: 100)

    budget.record(owner: 1, footprint: 900)
    budget.record(owner: 2, footprint: 80)

    XCTAssertTrue(budget.admits(owner: 3, estimate: 100))
    XCTAssertFalse(budget.admits(owner: 3, estimate: 101))
    XCTAssertTrue(budget.admits(owner: 1, estimate: 900), "its own footprint is not counted twice")

    budget.release(owner: 1)

    XCTAssertEqual(budget.used, 80)
    XCTAssertTrue(budget.admits(owner: 3, estimate: 500))
  }

  /// Catches a bitmap budget that leaves a pane blank. A lease past the limit still gets its floor,
  /// and a pane over its floor is refused until another lease gives memory back.
  func testTheBitmapBudgetKeepsAFloorForEveryPane() {
    let budget = ImageBitmapBudget(limit: 1000, floor: 100)
    let big = budget.makeLease()
    let late = budget.makeLease()

    XCTAssertTrue(budget.reserve(1000, lease: big))
    XCTAssertTrue(budget.reserve(100, lease: late), "inside the floor")
    XCTAssertFalse(budget.reserve(1, lease: late), "past the floor with the budget full")
    XCTAssertEqual(budget.used, 1100)

    budget.release(big)

    XCTAssertEqual(budget.used, 100)
    XCTAssertTrue(budget.reserve(500, lease: late))

    budget.giveBack(600, lease: late)

    XCTAssertEqual(budget.held(by: late), 0)
    XCTAssertEqual(budget.used, 0)
  }

  /// Catches fit math that enlarges a small image or loses its aspect ratio.
  func testFitShrinksAndNeverEnlarges() {
    XCTAssertEqual(
      FitMath.fitSize(
        image: PixelSize(width: 4000, height: 2000), in: PixelSize(width: 1000, height: 1000)),
      PixelSize(width: 1000, height: 500))
    XCTAssertEqual(
      FitMath.fitSize(
        image: PixelSize(width: 100, height: 50), in: PixelSize(width: 1000, height: 1000)),
      PixelSize(width: 100, height: 50))
    XCTAssertEqual(
      FitMath.fitSize(
        image: PixelSize(width: 100, height: 50), in: PixelSize(width: 0, height: 10)),
      PixelSize(width: 0, height: 0))
  }

  /// Catches a resize that asks for a sharper decode when the bitmap already has every pixel, or
  /// never asks when the pane grew past the bitmap.
  func testASharperDecodeIsNeededOnlyWhenThePaneOutgrowsTheBitmap() {
    let native = PixelSize(width: 4000, height: 3000)

    XCTAssertTrue(
      FitMath.needsSharperDecode(
        held: PixelSize(width: 800, height: 600), displayed: PixelSize(width: 1600, height: 1200),
        native: native))
    XCTAssertFalse(
      FitMath.needsSharperDecode(
        held: PixelSize(width: 800, height: 600), displayed: PixelSize(width: 400, height: 300),
        native: native))
    XCTAssertFalse(
      FitMath.needsSharperDecode(
        held: native, displayed: PixelSize(width: 8000, height: 6000), native: native))
    XCTAssertEqual(
      FitMath.requestedLongerSide(displayed: PixelSize(width: 9000, height: 5000), native: native),
      4000)
  }

  /// Catches an animation plan that runs off its frames, loses its delays, or keeps frames behind
  /// the one showing.
  func testTheAnimationPlanWrapsAndWindowsFrames() {
    let plan = AnimationPlan(delays: [100, 200, 300])

    XCTAssertTrue(plan.isAnimated)
    XCTAssertFalse(AnimationPlan(delays: [0]).isAnimated)
    XCTAssertEqual(plan.next(after: 2), 0)
    XCTAssertEqual(plan.delay(of: 1), 200)
    XCTAssertEqual(plan.delay(of: 9), 100)
    XCTAssertEqual(plan.window(from: 2, ahead: 2), [2, 0, 1])
    XCTAssertEqual(AnimationPlan(delays: [1, 1]).window(from: 0, ahead: 5), [0, 1])
  }
}
