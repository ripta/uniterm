import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

/// Drives the image viewer in the launched app, with the real signed and sandboxed helper. Each
/// test proves a contract that needs the real window server: the launcher entry, the open panel,
/// the pane's layout, a layout that comes back over a relaunch, and a close that never asks.
///
/// The color checks cannot be automated. Two tests attach screenshots of a Display P3 image and an
/// animated image, and the person reading the run compares them with Preview.
@MainActor
final class ImageViewerUITests: UnitermUITestCase {
  private let closeWindowsOnQuit = ["-NSQuitAlwaysKeepsWindows", "NO"]

  private func makeFolder() throws -> URL {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("uniterm-images-\(UUID().uuidString)", isDirectory: true)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }

    return folder
  }

  private func bitmap(
    width: Int, height: Int, space: CGColorSpace, fill: (Int, Int) -> (UInt8, UInt8, UInt8)
  ) -> CGImage {
    var bytes = [UInt8](repeating: 255, count: width * height * 4)

    for y in 0..<height {
      for x in 0..<width {
        let color = fill(x, y)
        let at = (y * width + x) * 4
        bytes[at] = color.0
        bytes[at + 1] = color.1
        bytes[at + 2] = color.2
      }
    }

    return CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
      space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
      shouldInterpolate: false, intent: .defaultIntent)!
  }

  @discardableResult
  private func writePNG(
    _ name: String, in folder: URL, width: Int = 400, height: Int = 200,
    space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
  ) throws -> URL {
    let picture = bitmap(width: width, height: height, space: space) { x, y in
      (UInt8(x * 255 / width), UInt8(y * 255 / height), 128)
    }

    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(
      data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, picture, nil)
    CGImageDestinationFinalize(destination)

    let file = folder.appendingPathComponent(name)
    try (data as Data).write(to: file)

    return file
  }

  private func writeGIF(_ name: String, in folder: URL) throws -> URL {
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(
      data, UTType.gif.identifier as CFString, 3, nil)!
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    CGImageDestinationSetProperties(
      destination,
      [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)

    for color in [(UInt8(255), UInt8(0), UInt8(0)), (0, 255, 0), (0, 0, 255)] {
      CGImageDestinationAddImage(
        destination, bitmap(width: 64, height: 64, space: space) { _, _ in color },
        [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.4]] as CFDictionary)
    }

    CGImageDestinationFinalize(destination)

    let file = folder.appendingPathComponent(name)
    try (data as Data).write(to: file)

    return file
  }

  private func plantViewer(path: String, kind: String, current: String? = nil) throws {
    let start =
      kind == "folder" ? path : URL(fileURLWithPath: path).deletingLastPathComponent().path
    let currentField = current.map { #","current":"\#($0)""# } ?? ""

    try plantLayout(
      """
      {"version":1,"windows":[{"frame":{"x":100,"y":100,"width":900,"height":600},"highWaterMark":1,
      "tree":{"kind":"pane","id":1,"applet":{"type":"image-viewer","version":1,
      "payload":{"startDirectory":"\(start)","path":"\(path)","kind":"\(kind)","sort":"name"\(currentField)}}}}]}
      """)
  }

  private func viewer(in window: XCUIElement) -> XCUIElement {
    window.descendants(matching: .any)["image-viewer"]
  }

  private func segment(_ index: Int, in window: XCUIElement) -> XCUIElement {
    window.descendants(matching: .any).matching(identifier: "status-applet-\(index)").firstMatch
  }

  private func attachScreenshot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  /// Chooses a file in the open panel that is already showing, by typing its path into the
  /// go-to-folder sheet.
  private func choose(_ file: URL, in app: XCUIApplication, window: XCUIElement) {
    let panel = window.sheets.firstMatch
    XCTAssertTrue(panel.waitForExistence(timeout: 10), "no open panel")

    app.typeKey("g", modifierFlags: [.command, .shift])

    let goTo = panel.sheets.firstMatch
    XCTAssertTrue(goTo.waitForExistence(timeout: 5), "no go-to-folder sheet")

    app.typeText(file.path)
    app.typeKey(.return, modifierFlags: [])
    XCTAssertTrue(waitUntilGone(goTo, timeout: 5), "the go-to-folder sheet never closed")

    app.typeKey(.return, modifierFlags: [])
    XCTAssertTrue(waitForNoSheet(in: window, timeout: 10), "the panel never closed")
  }

  /// Catches a launcher without the image viewer, a pane that does not offer to open an image, and
  /// an open panel that does not end in a picture. Cmd-D shows the launcher, Cmd-6 picks the image
  /// viewer, and the pane's Open button opens a panel that loads the chosen PNG and reports its
  /// size in the status bar.
  func testLauncherOpensAnEmptyViewerAndItsOpenButtonLoadsAnImage() throws {
    let file = try writePNG("shot.png", in: try makeFolder())
    let app = launchApp()
    let window = mainWindow(in: app)
    _ = waitForTerminal(in: app)

    app.typeKey("d", modifierFlags: .command)
    XCTAssertTrue(launcher(in: window).waitForExistence(timeout: 5))

    app.typeKey("6", modifierFlags: .command)
    app.typeKey(.return, modifierFlags: [])

    XCTAssertTrue(waitUntilGone(launcher(in: window)))
    XCTAssertTrue(viewer(in: window).waitForExistence(timeout: 10), "no image viewer pane")

    let open = window.buttons["image-viewer-open"]
    XCTAssertTrue(open.waitForExistence(timeout: 5), "an empty viewer has no Open button")
    open.click()

    choose(file, in: app, window: window)

    XCTAssertTrue(
      waitFor(segment(0, in: window), timeout: 20) { $0 == "400 \u{00D7} 200" },
      "the image never showed. The sandboxed helper may not have started.")
    XCTAssertFalse(
      window.buttons["image-viewer-open"].exists, "the Open button stays over the image")
    attachScreenshot("image viewer, sRGB PNG")
  }

  /// Catches a layout that loses the folder or its current image over a relaunch, and a restore that
  /// shows the wrong picture. A planted folder pane restores on its second image at fit, and a
  /// quit saves a layout that holds the path and no pixels.
  func testARestoredFolderPaneShowsItsCurrentImageAndSavesNoPixels() throws {
    let folder = try makeFolder()

    for name in ["a.png", "b.png", "c.png"] { try writePNG(name, in: folder) }

    try plantViewer(path: folder.path, kind: "folder", current: "b.png")

    let app = launchApp(
      environment: ["UNITERM_LAYOUT_DEBOUNCE": "3600"], arguments: closeWindowsOnQuit)
    let window = mainWindow(in: app)

    XCTAssertTrue(viewer(in: window).waitForExistence(timeout: 20), "no image viewer pane")
    XCTAssertTrue(waitFor(segment(1, in: window), timeout: 20) { $0 == "2 of 3" })

    app.typeKey("q", modifierFlags: .command)
    XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))

    let written = try String(
      contentsOf: layoutDirectory.appendingPathComponent("layout.json"), encoding: .utf8
    ).replacingOccurrences(of: "\\/", with: "/")

    XCTAssertTrue(written.contains(folder.path), "the path was not saved: \(written)")
    XCTAssertTrue(written.contains(#""current":"b.png""#))
    XCTAssertLessThan(written.utf8.count, 4096, "pixels were saved in the layout")
  }

  /// Catches a close that asks while an animation plays. Cmd-W on the second pane closes it with no
  /// sheet, and the terminal beside it keeps running.
  func testClosingAnAnimatingViewerNeverAsks() throws {
    let file = try writeGIF("loop.gif", in: try makeFolder())

    try plantLayout(
      """
      {"version":1,"windows":[{"frame":{"x":100,"y":100,"width":1000,"height":600},"highWaterMark":3,
      "focusedPane":2,"tree":{"kind":"split","id":3,"axis":"row","children":[
      {"weight":0.5,"node":{"kind":"pane","id":1,"applet":{"type":"terminal","version":1,"payload":{}}}},
      {"weight":0.5,"node":{"kind":"pane","id":2,"applet":{"type":"image-viewer","version":1,
      "payload":{"startDirectory":"\(file.deletingLastPathComponent().path)","path":"\(file.path)","kind":"file","sort":"name"}}}}]}}]}
      """)

    let app = launchApp()
    let window = mainWindow(in: app)

    XCTAssertTrue(waitFor(segment(0, in: window), timeout: 20) { $0 == "64 \u{00D7} 64" })
    attachScreenshot("image viewer, animated GIF")

    app.typeKey("w", modifierFlags: .command)

    XCTAssertTrue(waitForNoSheet(in: window, timeout: 3), "closing the viewer asked a question")
    XCTAssertTrue(window.exists)
  }

  /// Attaches a Display P3 image for comparison with Preview. The green here lies outside sRGB, so
  /// a viewer that converts to sRGB shows a duller green than Preview does. The test only proves
  /// that the image shows. The comparison is left to the person reading the attachment.
  func testADisplayP3ImageShowsForComparisonWithPreview() throws {
    let folder = try makeFolder()
    let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
    let picture = bitmap(width: 400, height: 200, space: p3) { x, _ in
      x < 200 ? (30, 220, 70) : (220, 40, 40)
    }
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(
      data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, picture, nil)
    CGImageDestinationFinalize(destination)

    let file = folder.appendingPathComponent("p3.png")
    try (data as Data).write(to: file)
    try plantViewer(path: file.path, kind: "file", current: "p3.png")

    let app = launchApp()
    let window = mainWindow(in: app)

    XCTAssertTrue(waitFor(segment(0, in: window), timeout: 20) { $0 == "400 \u{00D7} 200" })
    attachScreenshot("image viewer, Display P3 image (compare with Preview)")
  }
}
