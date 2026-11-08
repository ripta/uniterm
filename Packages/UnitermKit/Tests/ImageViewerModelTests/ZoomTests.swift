import CoreGraphics
import ImageWire
import XCTest

@testable import ImageViewerModel

final class ZoomViewportTests: XCTestCase {
  private let pane = CGSize(width: 800, height: 600)

  /// Catches fit enlarging a small image. A 400 by 200 image in an 800 by 600 pane stays at actual
  /// size, and a large one shrinks until it fits.
  func testFitNeverEnlargesPastActualSize() {
    let small = ZoomViewport(
      native: PixelSize(width: 400, height: 200), pane: pane, actualScale: 1)
    let large = ZoomViewport(
      native: PixelSize(width: 4000, height: 3000), pane: pane, actualScale: 1)

    XCTAssertEqual(small.scale, 1)
    XCTAssertTrue(small.isFit)
    XCTAssertEqual(large.scale, 0.2, accuracy: 1e-9)
    XCTAssertEqual(large.imageSize.width, 800, accuracy: 1e-9)
  }

  /// Catches a Retina screenshot shown at its pixel size. A file at 144 dots per inch is half as
  /// many points as pixels, which is the size Preview shows it at. A file with no resolution is
  /// one point per pixel.
  func testActualSizeHonorsTheDeclaredResolution() {
    let retina = SourceInfo(
      source: 1, width: 1600, height: 1000, frameDelays: [0], dpiX: 144, dpiY: 144)
    let plain = SourceInfo(source: 1, width: 1600, height: 1000, frameDelays: [0])
    let photo = SourceInfo(
      source: 1, width: 600, height: 400, frameDelays: [0], dpiX: 300, dpiY: 300)

    XCTAssertEqual(retina.actualScale, 0.5)
    XCTAssertEqual(plain.actualScale, 1)
    XCTAssertEqual(photo.actualScale, 0.24, accuracy: 1e-9)

    let native = PixelSize(width: 1600, height: 1000)
    var view = ZoomViewport(
      native: native, pane: CGSize(width: 4000, height: 3000), actualScale: 0.5)

    XCTAssertEqual(view.imageSize.width, 800, accuracy: 1e-9, "fit is actual size, not enlarged")

    view.setScale(2, backing: 2)
    view.showActualSize(backing: 2)

    XCTAssertEqual(view.scale, 0.5, "actual size is the declared size and fit here")
    XCTAssertTrue(view.isFit)
  }

  /// Catches Actual Size ignoring the image when it is larger than the pane. At actual size a
  /// 4000 by 3000 image at 72 dots per inch is 4000 points wide, and the pane shows part of it.
  func testActualSizeOfALargeImageShowsPartOfItAndZoomToFitComesBack() {
    var view = ZoomViewport(
      native: PixelSize(width: 4000, height: 3000), pane: pane, actualScale: 1)

    view.showActualSize(backing: 2)

    XCTAssertFalse(view.isFit)
    XCTAssertEqual(view.scale, 1)
    XCTAssertEqual(view.visibleRect.width, 800, accuracy: 1e-6)
    XCTAssertEqual(view.visibleRect.midX, 2000, accuracy: 1e-6)

    view.showFit()

    XCTAssertTrue(view.isFit)
    XCTAssertEqual(view.scale, 0.2, accuracy: 1e-9)
  }

  /// Catches a pan that shows space past the image. After a huge drag in every direction the
  /// visible rectangle stays inside the image, so no blank edge appears past the backdrop.
  func testPanningNeverShowsPastTheImageEdges() {
    var view = ZoomViewport(
      native: PixelSize(width: 4000, height: 3000), pane: pane, actualScale: 1)

    view.showActualSize(backing: 2)

    for delta in [
      CGSize(width: 1e6, height: 1e6), CGSize(width: -1e6, height: -1e6),
      CGSize(width: 1e6, height: -1e6), CGSize(width: -1e6, height: 1e6),
    ] {
      view.pan(byPoints: delta)

      let visible = view.visibleRect
      let origin = view.origin

      XCTAssertGreaterThanOrEqual(visible.minX, 0)
      XCTAssertGreaterThanOrEqual(visible.minY, 0)
      XCTAssertLessThanOrEqual(visible.maxX, 4000 + 1e-6)
      XCTAssertLessThanOrEqual(visible.maxY, 3000 + 1e-6)
      XCTAssertLessThanOrEqual(origin.x, 1e-9)
      XCTAssertGreaterThanOrEqual(origin.x + view.imageSize.width, pane.width - 1e-9)
      XCTAssertLessThanOrEqual(origin.y, 1e-9)
      XCTAssertGreaterThanOrEqual(origin.y + view.imageSize.height, pane.height - 1e-9)
    }
  }

  /// Catches an image smaller than the pane drifting off center when it is zoomed, and a pan
  /// moving an image that fits.
  func testAnImageSmallerThanThePaneStaysCentered() {
    var view = ZoomViewport(
      native: PixelSize(width: 100, height: 50), pane: pane, actualScale: 1)

    view.pan(byPoints: CGSize(width: 40, height: 40))
    XCTAssertEqual(view.origin.x, 350)

    view.setScale(2, backing: 2)
    view.pan(byPoints: CGSize(width: 300, height: -300))

    XCTAssertEqual(view.origin.x, (800 - 200) / 2)
    XCTAssertEqual(view.origin.y, (600 - 100) / 2)
  }

  /// Catches a zoom that slides the image out from under the cursor. The image point under the
  /// anchor stays under it after the scale changes.
  func testZoomingAboutAnAnchorKeepsThePointUnderIt() {
    var view = ZoomViewport(
      native: PixelSize(width: 4000, height: 3000), pane: pane, actualScale: 1)

    view.showActualSize(backing: 2)
    view.pan(byPoints: CGSize(width: -500, height: -300))

    let anchor = CGPoint(x: 200, y: 150)
    let before = view.origin
    let pixel = CGPoint(
      x: (anchor.x - before.x) / view.scale, y: (anchor.y - before.y) / view.scale)

    view.setScale(2, anchor: anchor, backing: 2)

    let after = view.origin

    XCTAssertEqual((anchor.x - after.x) / view.scale, pixel.x, accuracy: 1e-6)
    XCTAssertEqual((anchor.y - after.y) / view.scale, pixel.y, accuracy: 1e-6)
  }

  /// Catches a zoom with no limits. Zoom out stops at fit, and zoom in stops at 32 device pixels
  /// per image pixel.
  func testZoomIsBoundedByFitAndByAMagnificationLimit() {
    var view = ZoomViewport(
      native: PixelSize(width: 4000, height: 3000), pane: pane, actualScale: 1)

    view.setScale(0.001, backing: 2)
    XCTAssertTrue(view.isFit)

    view.setScale(1e9, backing: 2)
    XCTAssertEqual(view.scale, 16, "32 device pixels at a backing scale of 2")
  }

  /// Catches a step that jumps over 100 percent. Zooming in from fit stops at actual size on the
  /// way past it, and so does zooming out from beyond it.
  func testStepsStopAtActualSize() {
    var view = ZoomViewport(
      native: PixelSize(width: 4000, height: 3000), pane: pane, actualScale: 1)

    view.setScale(view.steppedScale(zoomingIn: true), backing: 2)
    XCTAssertEqual(view.scale, 0.4, accuracy: 1e-9)

    view.setScale(view.steppedScale(zoomingIn: true), backing: 2)
    XCTAssertEqual(view.scale, 0.8, accuracy: 1e-9)

    view.setScale(view.steppedScale(zoomingIn: true), backing: 2)
    XCTAssertEqual(view.scale, 1, "the step that would pass 100 percent lands on it")

    view.setScale(view.steppedScale(zoomingIn: true), backing: 2)
    XCTAssertEqual(view.scale, 2)

    view.setScale(view.steppedScale(zoomingIn: false), backing: 2)
    view.setScale(view.steppedScale(zoomingIn: false), backing: 2)
    XCTAssertEqual(view.scale, 0.5, accuracy: 1e-9)
  }

  /// Catches a resize that leaves a zoomed view stale. A pane that grows until fit reaches the
  /// zoom shows fit again, and a free zoom keeps its scale and clamps its pan.
  func testResizeKeepsFreeZoomAndFallsBackToFitWhenFitCatchesUp() {
    var view = ZoomViewport(
      native: PixelSize(width: 4000, height: 3000), pane: pane, actualScale: 1)

    view.showActualSize(backing: 2)
    view.pan(byPoints: CGSize(width: -1e6, height: -1e6))
    view.resize(pane: CGSize(width: 400, height: 300))

    XCTAssertFalse(view.isFit)
    XCTAssertEqual(view.scale, 1)
    XCTAssertLessThanOrEqual(view.visibleRect.maxX, 4000 + 1e-6)

    view.resize(pane: CGSize(width: 4000, height: 3000))

    XCTAssertTrue(view.isFit)
    XCTAssertEqual(view.scale, 1)
  }
}

final class TileMathTests: XCTestCase {
  /// Catches a level that asks for more than native, or one that jumps on every pinch step. At
  /// 1:1 the level is the whole image, above it nothing larger is decoded, and between fit and
  /// 1:1 it is a power-of-two fraction that is never below the device resolution.
  func testTheLevelIsCappedAtNativeAndQuantized() {
    let native = PixelSize(width: 8000, height: 4000)

    XCTAssertEqual(TileLevel(native: native, scale: 1, backing: 2).longerSide, 8000)
    XCTAssertEqual(TileLevel(native: native, scale: 16, backing: 2).longerSide, 8000)
    XCTAssertEqual(TileLevel(native: native, scale: 0.5, backing: 2).longerSide, 8000)
    XCTAssertEqual(TileLevel(native: native, scale: 0.3, backing: 2).longerSide, 8000)
    XCTAssertEqual(TileLevel(native: native, scale: 0.26, backing: 2).longerSide, 8000)
    XCTAssertEqual(TileLevel(native: native, scale: 0.25, backing: 2).longerSide, 4000)
    XCTAssertEqual(TileLevel(native: native, scale: 0.2, backing: 2).longerSide, 4000)
    XCTAssertEqual(TileLevel(native: native, scale: 0.12, backing: 2).longerSide, 2000)
    XCTAssertEqual(TileLevel(native: native, scale: 0.1, backing: 1).longerSide, 1000)
  }

  /// Catches tile rectangles that overlap, leave a gap, or run past the level. Every pixel of the
  /// level is in exactly one tile, and the edge tiles are cut.
  func testTilesCoverTheLevelExactlyOnce() {
    let level = TileLevel(native: PixelSize(width: 1300, height: 700), scale: 1, backing: 1)
    let columns = (level.width + TileMath.tileSize - 1) / TileMath.tileSize
    let rows = (level.height + TileMath.tileSize - 1) / TileMath.tileSize

    var area = 0

    for row in 0..<rows {
      for column in 0..<columns {
        let rect = level.rect(of: TileKey(level: level.longerSide, column: column, row: row))

        XCTAssertGreaterThan(rect.width, 0)
        XCTAssertLessThanOrEqual(rect.x + rect.width, level.width)
        XCTAssertLessThanOrEqual(rect.y + rect.height, level.height)

        area += rect.width * rect.height
      }
    }

    XCTAssertEqual(area, level.width * level.height)
  }

  /// Catches a wanted set that follows the image and not the pane. A 40000 by 30000 image at
  /// actual size shows an 800 by 600 pane, and the set holds the pane's tiles and one ring around
  /// them, never the 5,000 tiles of the image.
  func testTheWantedSetFollowsThePaneNotTheImage() {
    var view = ZoomViewport(
      native: PixelSize(width: 40000, height: 30000), pane: CGSize(width: 800, height: 600),
      actualScale: 1)

    view.showActualSize(backing: 2)

    let level = TileLevel(native: view.native, scale: view.scale, backing: 2)
    let wanted = TileMath.wanted(visible: view.visibleRect, in: level)

    XCTAssertEqual(level.longerSide, 40000)
    XCTAssertLessThanOrEqual(
      wanted.count, TileMath.capacity(pane: view.pane, backing: 2))
    XCTAssertLessThan(wanted.count, 40, "\(wanted.count)")

    let middle = TileKey(level: 40000, column: 20000 / 512, row: 15000 / 512)
    XCTAssertEqual(wanted.first, middle, "the tile under the middle of the pane comes first")
  }

  /// Catches a pan that grows the wanted set. Walking across the whole image never wants more
  /// tiles than the capacity for the pane.
  func testPanningAcrossAHugeImageNeverWantsMoreThanTheCapacity() {
    var view = ZoomViewport(
      native: PixelSize(width: 60000, height: 40000), pane: CGSize(width: 1400, height: 900),
      actualScale: 1)

    view.showActualSize(backing: 2)

    let capacity = TileMath.capacity(pane: view.pane, backing: 2)
    var biggest = 0

    for step in 0..<400 {
      view.pan(byPoints: CGSize(width: -137.5, height: step % 7 == 0 ? -61.25 : 0))

      let level = TileLevel(native: view.native, scale: view.scale, backing: 2)
      biggest = max(biggest, TileMath.wanted(visible: view.visibleRect, in: level).count)
    }

    XCTAssertLessThanOrEqual(biggest, capacity)
    XCTAssertGreaterThan(biggest, 1)
  }

  /// Catches a cache that grows with the pan. Inserting more tiles than the capacity lets the
  /// oldest go and hands them back, so the owner can return their bytes to the budget.
  func testTheCacheDropsTheLeastRecentlyUsedAndAccountsForItsBytes() {
    var cache = TileCache<Int>(capacity: 3)
    var held = 0

    for column in 0..<10 {
      let dropped = cache.insert(
        column, bytes: 100, for: TileKey(level: 1, column: column, row: 0))

      held += 100
      held -= dropped.reduce(0) { $0 + $1.bytes }

      XCTAssertLessThanOrEqual(cache.count, 3)
      XCTAssertEqual(cache.bytes, held)
    }

    XCTAssertTrue(cache.contains(TileKey(level: 1, column: 9, row: 0)))
    XCTAssertFalse(cache.contains(TileKey(level: 1, column: 0, row: 0)))

    let kept = Set([TileKey(level: 1, column: 9, row: 0)])
    let dropped = cache.retain(kept)

    XCTAssertEqual(dropped.count, 2)
    XCTAssertEqual(cache.count, 1)
  }
}

final class TileSchedulingTests: XCTestCase {
  private func request(_ id: UInt32, _ kind: DecodeRequest.Kind) -> DecodeRequest {
    DecodeRequest(
      id: id, source: 1, maxPixel: 100, frame: 0, kind: kind,
      region: kind == .tile ? TileRegion(level: 100, x: 0, y: 0, width: 10, height: 10) : nil)
  }

  /// Catches tile requests queuing up behind each other. Only the newest waits, so a pan sends the
  /// tiles for where the viewport is, and none for where it was.
  func testANewTileReplacesAWaitingTile() {
    var scheduler = RequestScheduler()

    XCTAssertNotNil(scheduler.submit(request(1, .tile)))
    XCTAssertNil(scheduler.submit(request(2, .tile)))
    XCTAssertNil(scheduler.submit(request(3, .tile)))
    XCTAssertEqual(scheduler.pending?.id, 3)
    XCTAssertEqual(scheduler.finish()?.id, 3)
  }

  /// Catches a tile that holds up a step or a resize. A still replaces a waiting tile, and a tile
  /// never replaces a waiting still, so the tiles of the image being left yield.
  func testAStillGoesAheadOfTilesAndATileNeverReplacesAStill() {
    var scheduler = RequestScheduler()

    _ = scheduler.submit(request(1, .tile))
    XCTAssertNil(scheduler.submit(request(2, .tile)))
    XCTAssertNil(scheduler.submit(request(3, .still)))
    XCTAssertEqual(scheduler.pending?.id, 3)

    XCTAssertNil(scheduler.submit(request(4, .tile)))
    XCTAssertEqual(scheduler.pending?.id, 3, "the tile was dropped, the still still waits")
  }

  /// Catches a tile that a prefetch could displace, and a prefetch that jumps a waiting tile.
  func testATileReplacesAWaitingPrefetchAndAPrefetchYieldsToATile() {
    var scheduler = RequestScheduler()

    _ = scheduler.submit(request(1, .still))
    XCTAssertNil(scheduler.submit(request(2, .prefetch)))
    XCTAssertEqual(scheduler.pending?.kind, .prefetch)

    XCTAssertNil(scheduler.submit(request(3, .tile)))
    XCTAssertEqual(scheduler.pending?.kind, .tile)

    XCTAssertNil(scheduler.submit(request(4, .prefetch)))
    XCTAssertEqual(scheduler.pending?.kind, .tile)
  }
}
