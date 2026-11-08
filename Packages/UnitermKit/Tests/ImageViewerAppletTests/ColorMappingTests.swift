import ImageWire
import XCTest

@testable import ImageDecoding
@testable import ImageViewerApplet

/// The helper draws into a named color space and the app wraps the bytes in the same one. Each side
/// builds the space from its own table, since the app never builds one from helper bytes. These
/// tests pin the two tables together.
final class ColorMappingTests: XCTestCase {
  /// Catches the helper and the app disagreeing about what a space name means. For every output
  /// space, both sides must build the same color space and the same bitmap layout. A drift would
  /// show as wrong colors, with nothing to flag it.
  func testTheHelperAndTheAppBuildTheSameSpaceAndLayoutForEveryName() throws {
    for space in OutputSpace.allCases {
      let helper = try XCTUnwrap(PixelRenderer.colorSpace(for: space), "\(space)")
      let app = try XCTUnwrap(BitmapFactory.colorSpace(for: space), "\(space)")

      XCTAssertEqual(helper.name as String?, app.name as String?, "\(space)")
      XCTAssertEqual(helper.numberOfComponents, app.numberOfComponents, "\(space)")
      XCTAssertEqual(
        PixelRenderer.bitmapInfo(for: space.format),
        BitmapFactory.bitmapInfo(for: space.format).rawValue,
        "\(space)")
    }
  }
}
