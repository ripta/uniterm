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

  /// The scroll phase field of a scroll CGEvent. Its values are 1 began, 2 changed, 4 ended.
  private static let scrollPhaseField = CGEventField(rawValue: 99)!

  private func phasedEvent(
    dy: Int32, inverted: Bool, phase: Int64, momentum: Int64
  ) throws -> NSEvent {
    let cg = try XCTUnwrap(
      CGEvent(
        scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: 0,
        wheel3: 0))

    cg.setIntegerValueField(Self.directionInvertedField, value: inverted ? 1 : 0)
    cg.setIntegerValueField(Self.scrollPhaseField, value: phase)
    cg.setIntegerValueField(Self.momentumPhaseField, value: momentum)
    cg.setIntegerValueField(CGEventField(rawValue: 88)!, value: 1)

    return try XCTUnwrap(NSEvent(cgEvent: cg))
  }

  /// A fixture whose red channel grows to the right and green channel grows downward, so the
  /// rendered pixel under a point says which part of the image is there.
  private func gradientView() throws -> (NSWindow, ImageViewerView) {
    let view = ImageViewerView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
    let window = NSWindow(
      contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)

    window.isReleasedWhenClosed = false
    window.contentView = view
    view.backingScaleSource = { 1 }
    view.show(
      image: ImageFixtures.bitmap(width: 1000, height: 1000) { x, y in
        (UInt8(x * 255 / 999), UInt8(y * 255 / 999), 0, 255)
      }, native: PixelSize(width: 1000, height: 1000), actualScale: 1, hdr: false)
    view.layoutSubtreeIfNeeded()

    XCTAssertTrue(view.zoom(.actual))
    view.pan(byPoints: CGSize(width: -300, height: -300))

    return (window, view)
  }

  /// The red and green channels under the middle of the view, as drawn.
  private func renderedCenter(_ view: ImageViewerView) throws -> (r: Int, g: Int) {
    let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))

    view.cacheDisplay(in: view.bounds, to: rep)

    let color = try XCTUnwrap(
      rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB))

    return (Int((color.redComponent * 255).rounded()), Int((color.greenComponent * 255).rounded()))
  }

  /// Catches an inverted pan axis between the viewport and the layers. A downward scroll delta
  /// drags the image down, as a scroll view's flipped document moves, so the middle of the pane
  /// then shows a part of the image nearer its top.
  func testRenderedImageFollowsTheScrollDelta() throws {
    let (window, view) = try gradientView()

    defer { window.close() }

    let start = try renderedCenter(view)

    view.scrollWheel(with: try scrollEvent(dx: 0, dy: 100, units: .pixel, inverted: false))

    let down = try renderedCenter(view)

    XCTAssertLessThan(down.g, start.g - 10, "downward delta did not drag the image down")
    XCTAssertEqual(down.r, start.r, accuracy: 6, "color conversion leaks across channels")

    view.scrollWheel(with: try scrollEvent(dx: 100, dy: 0, units: .pixel, inverted: false))

    let right = try renderedCenter(view)

    XCTAssertLessThan(right.r, down.r - 10, "rightward delta did not drag the image right")
    XCTAssertEqual(right.g, down.g, accuracy: 6)
  }

  /// Catches a phase-dependent branch in the pan. A two-finger gesture arrives as began, changed,
  /// and ended events, then as momentum events. Every one of them moves the image by its delta,
  /// whichever way the user's scroll direction setting points.
  func testPhasedGestureAndMomentumPanTheImageByEveryDelta() throws {
    let view = try zoomedView()

    for inverted in [false, true] {
      view.pan(byPoints: CGSize(width: 1e7, height: 1e7))
      view.pan(byPoints: CGSize(width: -1000, height: -1000))

      let stream: [(phase: Int64, momentum: Int64)] = [
        (1, 0), (2, 0), (2, 0), (2, 0), (4, 0), (0, 1), (0, 2), (0, 2), (0, 3),
      ]

      for (phase, momentum) in stream {
        let event = try phasedEvent(dy: 10, inverted: inverted, phase: phase, momentum: momentum)
        let before = try XCTUnwrap(view.imageFrame).origin

        view.scrollWheel(with: event)

        let after = try XCTUnwrap(view.imageFrame).origin

        XCTAssertEqual(
          after.y - before.y, 10, "phase \(event.phase) momentum \(event.momentumPhase)")
        XCTAssertEqual(after.x, before.x)
      }
    }
  }
}
