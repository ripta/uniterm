import AppKit
import ImageTestSupport
import ImageViewerModel
import XCTest

@testable import ImageViewerApplet

/// Checks that a scroll event pans the image the way it moves an NSScrollView's document. The
/// scroll view is the oracle for AppKit's own convention. AppKit applies the user's scroll
/// direction setting to `scrollingDelta*` before a view sees the event. A view that reads those
/// deltas as they are agrees with the scroll view under either setting.
///
/// The events carry no gesture phase. A scroll view fed a phased event straight from a test waits
/// for a tracking loop and does not move, so it cannot serve as the oracle for one.
@MainActor
final class ImageViewerScrollTests: XCTestCase {
  private final class FlippedDocument: NSView {
    override var isFlipped: Bool { true }
  }

  /// The CGEvent fields behind `isDirectionInvertedFromDevice` and `momentumPhase`. Neither is
  /// public API.
  private static let directionInvertedField = CGEventField(rawValue: 137)!
  private static let momentumPhaseField = CGEventField(rawValue: 123)!

  private func scrollEvent(
    dx: Int32, dy: Int32, units: CGScrollEventUnit, inverted: Bool, momentum: Int64 = 0
  ) throws -> NSEvent {
    let cg = try XCTUnwrap(
      CGEvent(
        scrollWheelEvent2Source: nil, units: units, wheelCount: 2, wheel1: dy, wheel2: dx,
        wheel3: 0))

    cg.setIntegerValueField(Self.directionInvertedField, value: inverted ? 1 : 0)
    cg.setIntegerValueField(Self.momentumPhaseField, value: momentum)

    let event = try XCTUnwrap(NSEvent(cgEvent: cg))

    XCTAssertEqual(event.isDirectionInvertedFromDevice, inverted)

    return event
  }

  private func sign(_ value: CGFloat) -> Int { value > 0 ? 1 : value < 0 ? -1 : 0 }

  /// A scroll view in a window, scrolled to the middle of a large document.
  private func scrolledScrollView() -> (NSWindow, NSScrollView) {
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
    let window = NSWindow(
      contentRect: scrollView.frame, styleMask: [.titled], backing: .buffered, defer: false)

    window.isReleasedWhenClosed = false
    window.contentView = scrollView
    scrollView.documentView = FlippedDocument(frame: NSRect(x: 0, y: 0, width: 4000, height: 4000))

    return (window, scrollView)
  }

  private func zoomedView() throws -> ImageViewerView {
    let view = ImageViewerView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
    view.backingScaleSource = { 1 }
    view.show(
      image: ImageFixtures.bitmap(width: 4000, height: 4000) { _, _ in ImageFixtures.blue },
      native: PixelSize(width: 4000, height: 4000), actualScale: 1, hdr: false)
    view.layoutSubtreeIfNeeded()

    XCTAssertTrue(view.zoom(.actual))
    view.pan(byPoints: CGSize(width: -1000, height: -1000))

    return view
  }

  /// Catches a pan that runs against the scroll view for the same event. Each case scrolls one
  /// axis, because a scroll view locks a plain wheel event to its dominant axis. It covers precise
  /// and line deltas, both signs, and both scroll direction settings.
  func testScrollMovesTheImageTheWayAScrollViewMovesItsDocument() throws {
    let (window, scrollView) = scrolledScrollView()
    let view = try zoomedView()

    defer { window.close() }

    for inverted in [false, true] {
      for units in [CGScrollEventUnit.pixel, .line] {
        for (dx, dy) in [(0, 40), (0, -40), (30, 0), (-30, 0)] as [(Int32, Int32)] {
          let event = try scrollEvent(dx: dx, dy: dy, units: units, inverted: inverted)
          let label = "\(units) \(dx),\(dy) inverted \(inverted)"

          scrollView.contentView.scroll(to: NSPoint(x: 1000, y: 1000))
          scrollView.reflectScrolledClipView(scrollView.contentView)
          scrollView.scrollWheel(with: event)
          RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))

          let origin = scrollView.contentView.bounds.origin
          let expected = CGSize(width: 1000 - origin.x, height: 1000 - origin.y)

          view.pan(byPoints: CGSize(width: 1e7, height: 1e7))
          view.pan(byPoints: CGSize(width: -1000, height: -1000))

          let before = try XCTUnwrap(view.imageFrame).origin

          view.scrollWheel(with: event)

          let after = try XCTUnwrap(view.imageFrame).origin

          XCTAssertNotEqual(sign(expected.width) + sign(expected.height), 0, "no oracle: \(label)")
          XCTAssertEqual(sign(after.x - before.x), sign(expected.width), "x for \(label)")
          XCTAssertEqual(sign(after.y - before.y), sign(expected.height), "y for \(label)")
        }
      }
    }
  }

  /// Catches a pan that drops momentum events, which would stop a flick the instant the fingers
  /// lift, and one that runs the image past its edge. Large momentum deltas pin the image to each
  /// corner in turn.
  func testMomentumKeepsPanningAndTheImageStopsAtItsEdges() throws {
    let view = try zoomedView()
    let began = try scrollEvent(dx: 0, dy: -50, units: .pixel, inverted: true, momentum: 1)
    let before = try XCTUnwrap(view.imageFrame).origin

    view.scrollWheel(with: began)

    XCTAssertEqual(try XCTUnwrap(view.imageFrame).origin.y, before.y - 50)

    for (dx, dy, x, y) in [
      (1_000_000, 1_000_000, 0.0, 0.0), (-1_000_000, -1_000_000, -3800.0, -3800.0),
    ] as [(Int32, Int32, CGFloat, CGFloat)] {
      let event = try scrollEvent(dx: dx, dy: dy, units: .pixel, inverted: false, momentum: 3)

      view.scrollWheel(with: event)

      let origin = try XCTUnwrap(view.imageFrame).origin

      XCTAssertEqual(origin.x, x)
      XCTAssertEqual(origin.y, y)
    }
  }
}
