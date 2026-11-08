import Foundation
import ImageTestSupport
import ImageWire
import XCTest

@testable import ImageDecoding

/// The app places tiles by `LevelGeometry`, and the helper draws its level at that size.
final class LevelGeometryTests: XCTestCase {
  private func opened(_ data: Data) throws -> OpenedImage {
    let path = NSTemporaryDirectory() + "uniterm-level-\(UUID().uuidString)"
    try data.write(to: URL(fileURLWithPath: path))
    defer { unlink(path) }

    let descriptor = open(path, O_RDONLY)

    return try OpenedImage(mapping: try FileMapping(descriptor: descriptor), sourceID: 1)
  }

  /// Catches a level whose size differs from the app's by a pixel. Across odd and extreme aspect
  /// ratios and many levels, the helper's level is exactly the size the shared function gives, so
  /// the tile the app clips equals the tile the helper cuts.
  func testTheHelperDrawsEveryLevelAtTheSharedSize() throws {
    let sizes = [
      (997, 601), (1000, 333), (4001, 3), (3, 4001), (1234, 1233), (640, 480), (1999, 1001),
      (777, 1555), (50, 49),
    ]

    for (width, height) in sizes {
      let image = try opened(ImageFixtures.png(width: width, height: height))
      let longer = max(width, height)

      for fraction in [1.0, 0.5, 0.25, 0.125, 0.3] {
        let level = max(1, Int((Double(longer) * fraction).rounded(.up)))
        let expected = LevelGeometry.size(
          nativeWidth: width, nativeHeight: height, longerSide: level)

        XCTAssertEqual(max(expected.width, expected.height), min(level, longer))

        let rendered = try PixelRenderer.render(
          image, frame: 0, maxPixel: level, exactSize: expected)

        XCTAssertEqual(
          [rendered.width, rendered.height], [expected.width, expected.height],
          "\(width) by \(height) at \(level)")
      }
    }
  }
}
