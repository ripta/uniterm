import AppKit
import ImageTestSupport
import ImageViewerModel
import XCTest

@testable import ImageViewerApplet

/// The view's placement of the backdrop and the tiles, checked by rendering its layers. A tile that
/// lands in the wrong corner is invisible to a test that reads frames only, so these read pixels.
/// A flipped view's backing layer is top-down on screen, and `render(in:)` draws y-up, so the helper
/// flips the context. Package tests cannot see the window server. The UI test
/// `ImageViewerUITests.testDragAndScrollMoveAZoomedImageTheRightWay` pins what shows on screen.
@MainActor
final class ImageViewerViewTests: XCTestCase {
  private func render(_ view: ImageViewerView) throws -> (_ x: Int, _ y: Int) -> [UInt8] {
    let width = Int(view.bounds.width)
    let height = Int(view.bounds.height)

    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))

    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)

    view.layer?.render(in: context)

    let data = try XCTUnwrap(context.data)

    // Copy the pixels out while the context is certainly alive. The returned closure then owns a
    // plain array and never touches the context's buffer after the context goes away.
    let bytes = Array(
      UnsafeBufferPointer(
        start: data.assumingMemoryBound(to: UInt8.self), count: width * height * 4))

    return { x, y in
      let at = (y * width + x) * 4

      return Array(bytes[at..<at + 4])
    }
  }

  private func solid(_ pixel: ImageFixtures.Pixel, size: Int) -> CGImage {
    ImageFixtures.bitmap(width: size, height: size) { _, _ in pixel }
  }

  /// Catches a tile drawn in the wrong corner. The 400 by 400 backdrop is blue. At actual size in a
  /// 200 by 200 pane the middle of the image shows, and a red tile that covers the image's top left
  /// quadrant shows in the top left of the pane. The bottom right keeps the backdrop.
  func testATileLandsWhereItsPartOfTheImageIs() throws {
    let view = ImageViewerView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
    view.backingScaleSource = { 1 }

    let native = PixelSize(width: 400, height: 400)

    view.show(
      image: solid(ImageFixtures.blue, size: 400), native: native, actualScale: 1, hdr: false)
    view.layoutSubtreeIfNeeded()

    XCTAssertTrue(view.zoom(.actual))

    let key = TileKey(level: 400, column: 0, row: 0)

    view.setTiles([
      TileSprite(
        key: key, image: solid(ImageFixtures.red, size: 200),
        rect: (x: 0, y: 0, width: 200, height: 200), ratio: 1, hdr: false)
    ])

    XCTAssertEqual(view.tileCount, 1)

    let pixel = try render(view)

    XCTAssertEqual(pixel(50, 50), [255, 0, 0, 255], "the tile covers the top left of the pane")
    XCTAssertEqual(pixel(150, 150), [0, 0, 255, 255], "the backdrop shows where no tile is")
    XCTAssertEqual(pixel(150, 50), [0, 0, 255, 255])
    XCTAssertEqual(pixel(50, 150), [0, 0, 255, 255])
  }

  /// Catches a tile that keeps a layer after it leaves the set. Replacing the set with an empty one
  /// removes every layer, and a smaller set keeps only its own.
  func testReplacingTheTilesRemovesTheLayersOfTheOnesThatLeft() throws {
    let view = ImageViewerView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
    view.backingScaleSource = { 1 }
    view.show(
      image: solid(ImageFixtures.blue, size: 400), native: PixelSize(width: 400, height: 400),
      actualScale: 1, hdr: false)
    view.zoom(.actual)

    func sprite(_ column: Int) -> TileSprite {
      TileSprite(
        key: TileKey(level: 400, column: column, row: 0), image: solid(ImageFixtures.red, size: 8),
        rect: (x: column * 8, y: 0, width: 8, height: 8), ratio: 1, hdr: false)
    }

    view.setTiles([sprite(0), sprite(1), sprite(2)])
    XCTAssertEqual(view.tileCount, 3)

    view.setTiles([sprite(1)])
    XCTAssertEqual(view.tileCount, 1)

    view.setTiles([])
    XCTAssertEqual(view.tileCount, 0)
  }

  /// Catches a pinch that asks for tiles on every event. While a pinch runs the view scales what it
  /// holds and says nothing. When it ends the view reports a settled viewport once.
  func testAPinchScalesWhatIsHeldAndReportsOnceWhenItEnds() throws {
    let view = ImageViewerView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
    view.backingScaleSource = { 1 }
    view.show(
      image: solid(ImageFixtures.blue, size: 400), native: PixelSize(width: 400, height: 400),
      actualScale: 1, hdr: false)
    view.layoutSubtreeIfNeeded()

    var reports: [ViewportChange] = []
    view.onViewportChange = { reports.append($0) }

    let scale = try XCTUnwrap(view.viewport?.scale)

    let middle = CGPoint(x: 100, y: 100)

    view.pinch(.began, magnification: 0, at: middle)
    XCTAssertTrue(view.isPinching)

    view.pinch(.changed, magnification: 0.5, at: middle)
    view.pinch(.changed, magnification: 0.5, at: middle)

    XCTAssertGreaterThan(try XCTUnwrap(view.viewport?.scale), scale)
    XCTAssertEqual(reports, [], "no tile request while the fingers move")

    view.pinch(.ended, magnification: 0, at: middle)

    XCTAssertFalse(view.isPinching)
    XCTAssertEqual(reports, [.settled])
  }

  private func pinchingView() -> (ImageViewerView, NSWindow) {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled],
      backing: .buffered, defer: true)

    window.isReleasedWhenClosed = false

    let view = ImageViewerView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))

    window.contentView = view
    view.backingScaleSource = { 1 }
    view.show(
      image: solid(ImageFixtures.blue, size: 400), native: PixelSize(width: 400, height: 400),
      actualScale: 1, hdr: false)
    view.pinch(.began, magnification: 0, at: CGPoint(x: 100, y: 100))

    return (view, window)
  }

  /// Catches a pinch that never ends. If the window loses key mid-gesture, AppKit may not send the
  /// end event, and tile work would stay off until the next gesture. Losing key, leaving the
  /// window, and showing another image each end the pinch, and the owner hears one settled
  /// viewport for the first two.
  func testAPinchWhoseEndNeverComesIsClearedByLosingKeyLeavingAndANewImage() {
    let (view, window) = pinchingView()
    var reports: [ViewportChange] = []
    view.onViewportChange = { reports.append($0) }

    XCTAssertTrue(view.isPinching)
    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
    XCTAssertFalse(view.isPinching)
    XCTAssertEqual(reports, [.settled])

    view.pinch(.began, magnification: 0, at: .zero)
    window.contentView = NSView()
    XCTAssertFalse(view.isPinching)
    XCTAssertEqual(reports, [.settled, .settled])

    let (other, _) = pinchingView()
    other.show(
      image: solid(ImageFixtures.red, size: 100), native: PixelSize(width: 100, height: 100),
      actualScale: 1, hdr: false)
    XCTAssertFalse(other.isPinching)
  }
}
