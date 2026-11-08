import AppKit
import ImageTestSupport
import ImageViewerModel
import XCTest

@testable import ImageViewerApplet

/// A two-finger double-tap ("smart zoom") toggles between fit and actual size. The events here are
/// real `.smartMagnify` events, built from a gesture CGEvent and delivered through the window.
/// XCUITest has no smart-magnify API, so the UI tests cannot drive this gesture.
@MainActor
final class ImageViewerSmartMagnifyTests: XCTestCase {
  /// The gesture CGEvent type, and the field that holds its subtype. A subtype of 22 decodes as
  /// smart magnify. Neither is public API.
  private static let gestureType = CGEventType(rawValue: 29)!
  private static let gestureSubtypeField = CGEventField(rawValue: 110)!
  private static let smartMagnifySubtype: Int64 = 22

  private func smartMagnify(at point: NSPoint, in window: NSWindow) throws -> NSEvent {
    let cg = try XCTUnwrap(CGEvent(source: nil))

    cg.type = Self.gestureType
    cg.setIntegerValueField(Self.gestureSubtypeField, value: Self.smartMagnifySubtype)

    // An event built from a CGEvent belongs to no window, so its `locationInWindow` is the location
    // it was built with, and the window takes that as its own coordinates. The window point goes in
    // directly. Only the flip from the CGEvent's y-down screen to AppKit's y-up one applies.
    let height = NSScreen.screens.first?.frame.height ?? 0

    cg.location = CGPoint(x: point.x, y: height - point.y)

    let event = try XCTUnwrap(NSEvent(cgEvent: cg))

    XCTAssertEqual(event.type, .smartMagnify)
    XCTAssertEqual(event.locationInWindow, point)

    return event
  }

  private func showing(
    native: Int, pane: CGFloat = 200, actualScale: Double = 1
  ) -> (NSWindow, ImageViewerView) {
    let view = ImageViewerView(frame: NSRect(x: 0, y: 0, width: pane, height: pane))
    let window = NSWindow(
      contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)

    window.isReleasedWhenClosed = false

    // Away from the screen's origin, where window and screen points would match by accident and
    // hide a tap built in the wrong coordinates.
    window.setFrameOrigin(NSPoint(x: 40, y: 63))
    window.contentView = view
    window.makeFirstResponder(view)

    view.backingScaleSource = { 1 }
    view.show(
      image: ImageFixtures.bitmap(width: native, height: native) { _, _ in ImageFixtures.blue },
      native: PixelSize(width: native, height: native), actualScale: actualScale, hdr: false)
    view.layoutSubtreeIfNeeded()

    return (window, view)
  }

  /// Catches a double-tap that never reaches the view, and one that zooms around the pane center
  /// and not the tap point. A 1000 pixel image fits a 200 point pane at 0.2. A tap at (50, 50) sits
  /// over image pixel (250, 250). At actual size that pixel stays under the pointer, so the image
  /// origin lands at (-200, -200). A zoom around the center would put it at (-400, -400).
  func testDoubleTapZoomsToActualSizeAroundThePointerAndBackToFit() throws {
    let (window, view) = showing(native: 1000)

    defer { window.close() }

    let tap = try smartMagnify(at: NSPoint(x: 50, y: 150), in: window)

    window.sendEvent(tap)

    let zoomed = try XCTUnwrap(view.viewport)

    XCTAssertFalse(zoomed.isFit)
    XCTAssertEqual(zoomed.scale, 1)
    XCTAssertEqual(try XCTUnwrap(view.imageFrame).origin.x, -200, accuracy: 0.01)
    XCTAssertEqual(try XCTUnwrap(view.imageFrame).origin.y, -200, accuracy: 0.01)

    window.sendEvent(tap)

    XCTAssertEqual(view.viewport?.isFit, true)
  }

  /// Catches a double-tap that does nothing on an image already shown at actual size. The 100 pixel
  /// image in a 200 point pane fits at 1.0, so actual size changes nothing. The tap steps in once
  /// at the pointer, and the next tap returns to fit.
  func testDoubleTapOnAnImageThatFitsAtActualSizeStepsIn() throws {
    let (window, view) = showing(native: 100)

    defer { window.close() }

    let tap = try smartMagnify(at: NSPoint(x: 100, y: 100), in: window)

    window.sendEvent(tap)

    let zoomed = try XCTUnwrap(view.viewport)

    XCTAssertFalse(zoomed.isFit)
    XCTAssertEqual(zoomed.scale, 2)

    window.sendEvent(tap)

    XCTAssertEqual(view.viewport?.isFit, true)
  }

  /// Catches a double-tap whose zoom never reaches the owner, which would leave tiles and the
  /// status segment at the old zoom.
  func testDoubleTapReportsAMovedViewport() throws {
    let (window, view) = showing(native: 1000)

    defer { window.close() }

    var reports: [ViewportChange] = []

    view.onViewportChange = { reports.append($0) }

    window.sendEvent(try smartMagnify(at: NSPoint(x: 50, y: 150), in: window))

    XCTAssertEqual(reports, [.moved])
  }
}
