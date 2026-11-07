import AppKit
import AppletKit
import AppletTestSupport
import ImageIO
import ImageTestSupport
import ImageViewerModel
import ImageWire
import SourceAccess
import XCTest

@testable import ImageViewerApplet

/// Drives free zoom against a real helper process: the commands, the tiles, the budgets, and the
/// limits. The images are generated in code. The large one is 6000 by 4000, so a 1:1 decode of it
/// is 96 MiB and a pane of 300 points can hold only a few tiles of it.
@MainActor
final class ImageZoomTests: XCTestCase {
  private var folder: URL!
  private var panes: PaneFactory!

  private static let large = (width: 6000, height: 4000)

  override func setUp() async throws {
    folder = try ImageFixtures.makeFolder()
    panes = PaneFactory(folder: folder)
  }

  override func tearDown() async throws {
    panes.closeAll()

    try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
  }

  @discardableResult
  private func writeLarge(
    _ name: String = "big.png", properties: [CFString: Any] = [:]
  ) throws -> URL {
    let picture = ImageFixtures.solidQuadrants(
      width: Self.large.width, height: Self.large.height)

    return try ImageFixtures.write(
      ImageFixtures.encode(picture, as: .png, properties: properties), named: name, in: folder)
  }

  /// A pane at a backing scale of 2 that shows `file` at fit.
  private func open(
    _ file: URL, settings: HelperSettings? = nil,
    helperBudget: ImageHelperBudget = ImageHelperBudget(limit: 8 << 30, floor: 1 << 30),
    bitmapBudget: ImageBitmapBudget = ImageBitmapBudget(limit: 1 << 30, floor: 256 << 20)
  ) async throws -> (ImageViewerApplet, RecordingHost) {
    let (applet, host) = panes.make(
      settings: settings, helperBudget: helperBudget, bitmapBudget: bitmapBudget)

    applet.content.backingScaleSource = { 2 }
    try applet.replaceSource(with: file, startDirectory: folder.path)

    let shown = await Harness.eventually { applet.phase == .showing && applet.client.source != nil }
    XCTAssertTrue(shown, "\(applet.phase)")

    return (applet, host)
  }

  private func warnings(_ host: RecordingHost) -> [String] {
    host.sent.filter { $0.level == .warning }.map(\.text)
  }

  /// True when every tile the viewport wants is held.
  private func tilesSettled(_ applet: ImageViewerApplet) -> Bool {
    guard let viewport = applet.content.viewport, let level = applet.tileLevel else { return false }

    let wanted = TileMath.wanted(visible: viewport.visibleRect, in: level)

    return !wanted.isEmpty && wanted.allSatisfy { applet.tiles.contains($0) }
  }

  private func zoomSegment(_ applet: ImageViewerApplet) -> String? {
    applet.segments.first { $0.symbolName == "magnifyingglass" }?.text
  }

  private func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 4)

    bytes.withUnsafeMutableBytes { raw in
      let context = CGContext(
        data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

      context.draw(
        image,
        in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
    }

    return bytes
  }

  // MARK: Commands

  /// Catches a zoom that waits on the helper. The command changes the view and the status segment
  /// in the same turn, with the backdrop scaled to the new size and no tile yet. Tiles follow.
  func testZoomInChangesTheViewAtOnceAndTilesFollow() async throws {
    let (applet, _) = try await open(try writeLarge())

    XCTAssertTrue(applet.content.viewport?.isFit == true)
    XCTAssertNil(zoomSegment(applet))

    applet.zoomIn()

    XCTAssertFalse(applet.content.viewport?.isFit ?? true)
    XCTAssertEqual(zoomSegment(applet), "10%")
    XCTAssertEqual(applet.content.tileCount, 0, "no tile has arrived, and the view did not wait")
    XCTAssertEqual(
      applet.content.imageFrame?.size, CGSize(width: 600, height: 400), "the backdrop scaled")
    XCTAssertTrue(applet.isZoomedPastFit)

    let settled = await Harness.eventually { self.tilesSettled(applet) }
    XCTAssertTrue(settled)
    XCTAssertEqual(applet.tileLevel?.longerSide, 1500, "a quarter of native covers the screen")
    XCTAssertEqual(applet.content.tileCount, applet.tiles.count)
  }

  /// Catches actual size, zoom out, and zoom to fit disagreeing with the viewport. Actual Size
  /// shows 100 percent and decodes at native, Zoom Out halves, and Zoom to Fit drops the segment,
  /// the tiles, and the prefetch gate.
  func testActualSizeZoomOutAndZoomToFitMoveBetweenStates() async throws {
    let (applet, _) = try await open(try writeLarge())

    applet.zoomToActualSize()
    XCTAssertEqual(zoomSegment(applet), "100%")

    let native = await Harness.eventually { self.tilesSettled(applet) }
    XCTAssertTrue(native)
    XCTAssertEqual(applet.tileLevel?.longerSide, 6000)

    applet.zoomOut()
    XCTAssertEqual(zoomSegment(applet), "50%")

    applet.zoomToFit()

    XCTAssertTrue(applet.content.viewport?.isFit == true)
    XCTAssertNil(zoomSegment(applet))
    XCTAssertEqual(applet.tiles.count, 0)
    XCTAssertEqual(applet.content.tileCount, 0)
    XCTAssertFalse(applet.isZoomedPastFit)

    applet.zoomOut()
    XCTAssertTrue(applet.content.viewport?.isFit == true, "zoom out stops at fit")
  }

  /// Catches the zoom commands staying on while they cannot act. An empty pane and an animation
  /// have nothing to zoom, so the registry turns the commands off.
  func testZoomCommandsAreOffWithoutAnImageAndForAnAnimation() async throws {
    let (empty, _) = panes.make()
    XCTAssertFalse(empty.canZoom)

    let gif = try ImageFixtures.write(
      ImageFixtures.animatedGIF(colors: [ImageFixtures.red, ImageFixtures.blue], delays: [5, 5]),
      named: "loop.gif", in: folder)
    let (animated, _) = try await open(gif)

    XCTAssertTrue(animated.plan.isAnimated)
    XCTAssertFalse(animated.canZoom)

    animated.zoomIn()
    XCTAssertTrue(animated.content.viewport?.isFit == true)
  }

  /// Catches Actual Size ignoring the declared resolution. A 3000 by 2000 PNG at 144 dots per
  /// inch is 1500 by 1000 points, so it fits a 2000 point pane at its own size, and zooming to
  /// actual size in a smaller pane shows 100 percent of that size.
  func testAFileAt144DotsPerInchShowsAtHalfItsPixelSize() async throws {
    let picture = ImageFixtures.solidQuadrants(width: 3000, height: 2000)
    let data = ImageFixtures.encode(
      picture, as: .png,
      properties: [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144])
    let file = try ImageFixtures.write(data, named: "retina.png", in: folder)

    let (applet, _) = try await open(file)

    XCTAssertEqual(applet.info?.dpiX, 144)
    XCTAssertEqual(applet.content.viewport?.actualScale, 0.5)

    applet.content.frame = NSRect(x: 0, y: 0, width: 2000, height: 1200)
    applet.content.layoutSubtreeIfNeeded()

    XCTAssertEqual(
      applet.content.imageFrame?.size, CGSize(width: 1500, height: 1000),
      "fit is actual size here, and actual size is half the pixels")
    XCTAssertTrue(applet.content.viewport?.isFit == true)
  }

  // MARK: Pan and keys

  /// Catches arrows that step a zoomed image away. Zoomed past fit, an arrow pans and the
  /// selection stays, while Space still steps. At fit an arrow steps again.
  func testArrowsPanAZoomedImageAndSpaceStillSteps() async throws {
    try ImageFixtures.write(
      ImageFixtures.encode(
        ImageFixtures.solidQuadrants(width: 3000, height: 2000), as: .png), named: "a.png",
      in: folder)
    try ImageFixtures.write(ImageFixtures.png(), named: "b.png", in: folder)

    let (applet, _) = panes.make()
    applet.content.backingScaleSource = { 2 }
    try applet.replaceSource(with: folder, startDirectory: folder.path)

    let first = await Harness.eventually {
      applet.phase == .showing && applet.committedName == "a.png" && applet.listing.isComplete
    }
    XCTAssertTrue(first)

    applet.zoomToActualSize()

    let before = try XCTUnwrap(applet.content.viewport)

    XCTAssertTrue(applet.handle(key: .right))
    XCTAssertEqual(applet.listing.index, 0, "the arrow panned and did not step")

    let after = try XCTUnwrap(applet.content.viewport)
    XCTAssertGreaterThan(after.centerX, before.centerX)

    XCTAssertTrue(applet.handle(key: .down))
    XCTAssertGreaterThan(try XCTUnwrap(applet.content.viewport).centerY, before.centerY)

    XCTAssertTrue(applet.handle(key: .space))

    let stepped = await Harness.eventually {
      applet.phase == .showing && applet.committedName == "b.png"
    }
    XCTAssertTrue(stepped, "Space still steps")
    XCTAssertTrue(applet.content.viewport?.isFit == true, "a step returns to fit")
    XCTAssertEqual(applet.tiles.count, 0)
    XCTAssertFalse(applet.isZoomedPastFit)

    XCTAssertTrue(applet.handle(key: .left))
    let back = await Harness.eventually { applet.committedName == "a.png" }
    XCTAssertTrue(back, "at fit an arrow steps")
  }

  /// Catches blank edges and unbounded memory while panning. Panning across a 6000 by 4000 image
  /// at actual size keeps the backdrop over the whole pane, never holds more tiles than the pane
  /// needs, and never charges the budget more than the backdrop and those tiles. The whole image
  /// at 1:1 is 96 MiB, and the pane holds a fraction of it.
  func testPanningAtActualSizeKeepsTheBackdropAndBoundsTheTilesAndTheBudget() async throws {
    let (applet, _) = try await open(try writeLarge())
    let backdrop = try XCTUnwrap(applet.shot).bytes

    applet.zoomToActualSize()

    let first = await Harness.eventually { self.tilesSettled(applet) }
    XCTAssertTrue(first)

    let pane = try XCTUnwrap(applet.content.viewport).pane
    let capacity = TileMath.capacity(pane: pane, backing: 2)
    let tileBytes = TileMath.tileSize * TileMath.tileSize * 4
    let bound = backdrop + capacity * tileBytes

    var peak = 0
    var peakTiles = 0

    for step in 0..<130 {
      XCTAssertTrue(applet.panImage(by: step < 70 ? .right : .down))

      let frame = try XCTUnwrap(applet.content.imageFrame)
      XCTAssertLessThanOrEqual(frame.minX, 0.001)
      XCTAssertLessThanOrEqual(frame.minY, 0.001)
      XCTAssertGreaterThanOrEqual(frame.maxX, 300 - 0.001, "blank edge on the right")
      XCTAssertGreaterThanOrEqual(frame.maxY, 300 - 0.001, "blank edge at the bottom")

      peak = max(peak, applet.bitmapBudget.held(by: applet.lease))
      peakTiles = max(peakTiles, applet.tiles.count)
      XCTAssertLessThanOrEqual(applet.tiles.count, capacity)

      if step % 10 == 0 { await Task.yield() }
    }

    let settled = await Harness.eventually { self.tilesSettled(applet) }
    XCTAssertTrue(settled)

    peak = max(peak, applet.bitmapBudget.held(by: applet.lease))

    XCTAssertLessThanOrEqual(peak, bound, "the budget holds the backdrop and a pane of tiles")
    XCTAssertLessThan(peak, 40 << 20, "far below the 96 MiB of the image at 1:1")
    XCTAssertGreaterThan(peakTiles, 1)
    XCTAssertEqual(applet.content.tileCount, applet.tiles.count)
  }

  /// Catches a tile drawn from the wrong part of the image. At the far top left of the image, the
  /// first tile starts with the red quadrant. At the far bottom right it ends in white.
  func testTilesCarryTheRegionOfTheImageTheyWereAskedFor() async throws {
    let (applet, _) = try await open(try writeLarge())

    applet.zoomToActualSize()
    applet.content.pan(byPoints: CGSize(width: 1e7, height: 1e7))

    let topLeft = await Harness.eventually { self.tilesSettled(applet) }
    XCTAssertTrue(topLeft)

    let origin = TileKey(level: 6000, column: 0, row: 0)
    let first = try XCTUnwrap(applet.tiles.entries[origin]).value.image
    XCTAssertEqual(pixel(first, x: 5, y: 5), [255, 0, 0, 255])

    applet.content.pan(byPoints: CGSize(width: -1e7, height: -1e7))

    let bottomRight = await Harness.eventually { self.tilesSettled(applet) }
    XCTAssertTrue(bottomRight)

    let last = TileKey(level: 6000, column: 11, row: 7)
    let tile = try XCTUnwrap(applet.tiles.entries[last]).value.image
    XCTAssertEqual(pixel(tile, x: tile.width - 1, y: tile.height - 1), [255, 255, 255, 255])
  }

  // MARK: Limits

  /// Catches a zoom past the app-wide helper budget that kills a neighbor or says nothing. The
  /// first pane's helper keeps running and decoding, and the second pane warns that the limit was
  /// reached and goes back to fit.
  func testZoomPastTheHelperBudgetIsRefusedWithAWarningAndNoOtherHelperIsKilled() async throws {
    let shared = ImageHelperBudget(limit: 200 << 20, floor: 80 << 20)
    let neighbor = try ImageFixtures.write(ImageFixtures.png(), named: "n.png", in: folder)
    let (calm, calmHost) = try await open(neighbor, helperBudget: shared)
    let calmProcess = calm.client.processID

    let (applet, host) = try await open(try writeLarge(), helperBudget: shared)

    applet.zoomToActualSize()

    let warned = await Harness.eventually {
      self.warnings(host).contains { $0.contains("zoom limit was reached") }
    }
    XCTAssertTrue(warned, "\(warnings(host))")
    XCTAssertTrue(applet.content.viewport?.isFit == true)
    XCTAssertEqual(applet.tiles.count, 0)
    XCTAssertEqual(applet.phase, .showing, "the pane keeps its image")

    XCTAssertTrue(calm.client.isRunning)
    XCTAssertEqual(calm.client.processID, calmProcess)
    XCTAssertTrue(warnings(calmHost).isEmpty)
  }

  /// Catches a refused zoom that drops the user to fit. With a step that works and then a step the
  /// helper cannot hold, the pane warns and returns to the zoom that showed tiles.
  func testARefusedZoomGoesBackToTheLastZoomThatWorked() async throws {
    let settings = Harness.settings(maxImageBytes: 50 << 20)
    let (applet, host) = try await open(try writeLarge(), settings: settings)

    applet.zoomIn()

    let worked = await Harness.eventually { self.tilesSettled(applet) }
    XCTAssertTrue(worked)

    let good = try XCTUnwrap(applet.content.viewport?.scale)

    applet.zoomToActualSize()

    let warned = await Harness.eventually {
      self.warnings(host).contains { $0.contains("zoom limit was reached") }
    }
    XCTAssertTrue(warned)
    XCTAssertEqual(applet.content.viewport?.scale, good)

    let again = await Harness.eventually { self.tilesSettled(applet) }
    XCTAssertTrue(again, "the tiles of the zoom that worked come back")
  }

  #if DEBUG
    /// Catches a slow but legitimate decode crashing the pane or leaving it blank. The helper takes
    /// longer than the time bound to cut the 1:1 decode, which the app ends. The status bar says the
    /// zoom limit was reached, the image stays at fit, and the pane opens it again.
    func testASlowZoomDecodeReportsTheLimitAndTheImageStays() async throws {
      let file = try writeLarge(
        properties: [
          kCGImagePropertyPNGDictionary: [
            kCGImagePropertyPNGDescription: "UNITERM-REGION-FAULT slow:5000"
          ]
        ])

      let settings = Harness.settings(timeBound: .milliseconds(1500))
      let (applet, host) = try await open(file, settings: settings)
      let pid = applet.client.processID

      applet.zoomToActualSize()

      let warned = await Harness.eventually {
        self.warnings(host).contains { $0.contains("zoom limit was reached") }
      }
      XCTAssertTrue(warned, "\(warnings(host))")
      XCTAssertTrue(applet.content.viewport?.isFit == true)
      XCTAssertEqual(applet.phase, .showing, "never an error pane, never a crash")

      let again = await Harness.eventually {
        applet.phase == .showing && applet.client.source != nil && applet.loadingName == nil
          && applet.client.processID != pid
      }
      XCTAssertTrue(again, "a fresh helper holds the image again")
      XCTAssertEqual(applet.tiles.count, 0)
    }
  #endif

  // MARK: Memory

  /// Catches a zoom refused for memory that other decodes hold. The budget has room for the
  /// backdrop and two more fit decodes, the previous image and the prefetched one, and not for a
  /// second tile beside them. Zoom lets the prefetch go and the tiles take the previous image's
  /// place, so the zoom shows detail and warns of nothing.
  func testZoomIsNeverRefusedForMemoryAPrefetchHolds() async throws {
    for name in ["a.png", "b.png", "c.png"] {
      try ImageFixtures.write(
        ImageFixtures.encode(
          ImageFixtures.solidQuadrants(width: 6000, height: 4000), as: .png), named: name,
        in: folder)
    }

    let (applet, host) = panes.make(
      bitmapBudget: ImageBitmapBudget(limit: 3_500_000, floor: 3_500_000))
    applet.content.backingScaleSource = { 2 }
    try applet.replaceSource(with: folder, startDirectory: folder.path)

    let opened = await Harness.eventually {
      applet.committedName == "a.png" && applet.listing.isComplete
    }
    XCTAssertTrue(opened)

    applet.step(.next)

    let held = await Harness.eventually {
      applet.committedName == "b.png" && applet.cache.previous?.name == "a.png"
        && applet.cache.prefetched?.name == "c.png"
    }
    XCTAssertTrue(held, "the previous and the prefetched image take their share of the budget")

    applet.zoomIn()

    let tiled = await Harness.eventually { applet.tiles.count >= 2 }
    XCTAssertTrue(tiled, "the tiles took the place of the images beside the one on screen")
    XCTAssertNil(applet.cache.prefetched)
    XCTAssertNil(applet.cache.previous)
    XCTAssertTrue(warnings(host).isEmpty, "\(warnings(host))")
  }

  /// Catches a helper that keeps an image it already sent. A prefetch of a 4000 by 4000 image is a
  /// 64 MiB decode, and once the reply is out the helper's footprint falls back toward its
  /// resting size.
  func testTheHelperReleasesAPrefetchedBitmapOnceItIsSent() async throws {
    let picture = ImageFixtures.solidQuadrants(width: 4000, height: 4000)
    let file = try ImageFixtures.write(
      ImageFixtures.encode(picture, as: .png), named: "square.png", in: folder)
    let spare = try ImageFixtures.write(ImageFixtures.png(), named: "spare.png", in: folder)

    let client = ImageHelperClient(
      settings: Harness.settings(), budget: ImageHelperBudget(limit: 8 << 30, floor: 1 << 30))
    defer { client.shutdown() }

    let log = EventLog(client)

    guard case .success(.file(let shown)) = SourceOpener.open(path: spare.path),
      case .success(.file(let next)) = SourceOpener.open(path: file.path)
    else { return XCTFail("the fixtures did not open") }

    client.open(shown)
    await expectEventually { log.opened != nil }

    let id = try XCTUnwrap(client.open(next, role: .prefetch))
    await expectEventually {
      log.events.contains { if case .prefetchOpened = $0 { return true } else { return false } }
    }

    let info = try XCTUnwrap(
      log.events.compactMap { event -> SourceInfo? in
        if case .prefetchOpened(let info) = event { return info } else { return nil }
      }.first)
    XCTAssertEqual(info.source, id)

    let resting = try XCTUnwrap(client.currentFootprint)

    XCTAssertNotNil(client.prefetch(info, maxPixel: 4000))
    await expectEventually { !log.images.isEmpty }

    let image = try XCTUnwrap(log.images.last)
    XCTAssertEqual([image.width, image.height], [4000, 4000])

    let released = await Harness.eventually {
      (client.currentFootprint ?? .max) < resting + (24 << 20)
    }
    XCTAssertTrue(
      released, "footprint \(client.currentFootprint ?? 0) against resting \(resting)")
  }

  // MARK: Detach and display scale

  /// Catches a detached pane that keeps its detail. Detach lets go of the tiles in the app and the
  /// decode in the helper, and keeps only the backdrop. Reattach asks for the tiles again.
  func testDetachReleasesTheTilesAndTheHelpersDecodeAndReattachRestoresThem() async throws {
    let (applet, _) = try await open(try writeLarge())
    let backdrop = try XCTUnwrap(applet.shot).bytes

    applet.zoomToActualSize()

    let tiled = await Harness.eventually { self.tilesSettled(applet) }
    XCTAssertTrue(tiled)

    let withLevel = try XCTUnwrap(applet.client.currentFootprint)
    XCTAssertGreaterThan(withLevel, 80 << 20, "the helper holds the 1:1 decode")

    applet.detach()

    XCTAssertEqual(applet.tiles.count, 0)
    XCTAssertEqual(applet.content.tileCount, 0)
    XCTAssertEqual(applet.bitmapBudget.held(by: applet.lease), backdrop)
    XCTAssertNotNil(applet.shot, "the backdrop stays")

    let released = await Harness.eventually {
      (applet.client.currentFootprint ?? .max) < withLevel / 2
    }
    XCTAssertTrue(released, "the helper let go of the decode")

    applet.reattach()

    let back = await Harness.eventually { self.tilesSettled(applet) }
    XCTAssertTrue(back)
  }

  /// Catches a display change that leaves the old pixel density. Moving the pane to a display with
  /// a different scale asks for a sharper backdrop at fit, and new tiles at a new level when
  /// zoomed.
  func testAChangeOfDisplayScaleRequestsNewPixels() async throws {
    let file = try writeLarge()
    let (applet, _) = panes.make()
    var scale: CGFloat = 1

    applet.content.backingScaleSource = { scale }
    try applet.replaceSource(with: file, startDirectory: folder.path)

    let shown = await Harness.eventually { applet.phase == .showing && applet.shot != nil }
    XCTAssertTrue(shown)
    XCTAssertEqual(applet.shownPixels?.longer, 300)

    scale = 2
    applet.content.viewDidChangeBackingProperties()

    let sharper = await Harness.eventually { applet.shownPixels?.longer == 600 }
    XCTAssertTrue(sharper, "\(String(describing: applet.shownPixels))")

    applet.zoomIn()
    let tiled = await Harness.eventually { self.tilesSettled(applet) }
    XCTAssertTrue(tiled)
    XCTAssertEqual(applet.tileLevel?.longerSide, 1500)

    scale = 1
    applet.content.viewDidChangeBackingProperties()

    let finer = await Harness.eventually {
      applet.tileLevel?.longerSide == 750 && self.tilesSettled(applet)
    }
    XCTAssertTrue(finer, "\(String(describing: applet.tileLevel))")
    XCTAssertTrue(applet.tiles.entries.keys.allSatisfy { $0.level == 750 })
  }
}
