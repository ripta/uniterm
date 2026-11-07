import XCTest

@testable import ImageWire

final class ImageExpectationTests: XCTestCase {
  private let expectation = ImageExpectation(
    request: 4, source: 2, frame: 0, maxPixel: 100, sourceWidth: 400, sourceHeight: 200,
    byteCap: 1 << 20)

  private func header(
    request: UInt32 = 4, source: UInt32 = 2, frame: UInt32 = 0, width: UInt32 = 100,
    height: UInt32 = 50, space: OutputSpace = .sRGB, format: PixelFormat = .rgba8
  ) -> ImageHeader {
    ImageHeader(
      request: request, source: source, frame: frame, width: width, height: height, space: space,
      format: format)
  }

  /// Catches a well-formed reply being refused. The byte count is the app's own, computed from the
  /// dimensions, and the reply matches it exactly.
  func testAMatchingImageIsAccepted() throws {
    try expectation.validate(header(), pixels: Data(count: 100 * 50 * 4))
    try expectation.validate(
      header(space: .extendedLinearDisplayP3, format: .rgbaF16), pixels: Data(count: 100 * 50 * 8))
  }

  /// Catches pixels one byte short or long being accepted. The buffer the app keeps is sized from
  /// the checked dimensions, so a mismatch is refused and never read.
  func testPixelsThatDoNotMatchTheDimensionsAreRefused() {
    XCTAssertThrowsError(try expectation.validate(header(), pixels: Data(count: 100 * 50 * 4 - 1)))
    XCTAssertThrowsError(try expectation.validate(header(), pixels: Data(count: 100 * 50 * 4 + 1)))
    XCTAssertThrowsError(try expectation.validate(header(), pixels: Data()))
  }

  /// Catches an image the app did not ask for: another request, another source, another frame, or a
  /// size larger than the longer side requested or than the source itself.
  func testAnImageThatAnswersAnotherRequestIsRefused() {
    for bad in [
      header(request: 5), header(source: 3), header(frame: 1), header(width: 101, height: 50),
      header(width: 100, height: 101),
    ] {
      let bytes = Data(count: Int(bad.width) * Int(bad.height) * 4)

      XCTAssertThrowsError(try expectation.validate(bad, pixels: bytes), "\(bad)")
    }
  }

  /// Catches dimensions that overflow, hit zero, or pass the cap. A hostile width and height would
  /// otherwise make the app allocate whatever the product says.
  func testImpossibleDimensionsAreRefusedWithoutOverflow() {
    let wide = ImageExpectation(
      request: 4, source: 2, frame: 0, maxPixel: 0, sourceWidth: .max, sourceHeight: .max,
      byteCap: .max)

    for (width, height) in [(UInt32.max, UInt32.max), (0, 5), (5, 0), (40_000, 40_000)] {
      XCTAssertThrowsError(
        try wide.validate(header(width: width, height: height), pixels: Data()),
        "\(width)x\(height)")
    }

    let small = ImageExpectation(
      request: 4, source: 2, frame: 0, maxPixel: 100, sourceWidth: 400, sourceHeight: 200,
      byteCap: 1000)

    XCTAssertThrowsError(try small.validate(header(), pixels: Data(count: 100 * 50 * 4)))
  }

  /// Catches a pixel format that does not belong to its color space, such as half-float pixels
  /// labeled sRGB. The app reads the buffer by its format, so the pair must agree.
  func testAFormatThatDoesNotSuitItsSpaceIsRefused() {
    XCTAssertThrowsError(
      try expectation.validate(header(space: .sRGB, format: .rgbaF16), pixels: Data(count: 40_000)))
    XCTAssertThrowsError(
      try expectation.validate(
        header(space: .extendedLinearDisplayP3, format: .rgba8), pixels: Data(count: 20_000)))
  }

  /// Catches the byte count helper trapping or wrapping at the edges of Int.
  func testByteCountReturnsNilInsteadOfOverflowing() {
    XCTAssertNil(ImageLimits.byteCount(width: .max, height: .max, format: .rgbaF16))
    XCTAssertNil(ImageLimits.byteCount(width: 0, height: 1, format: .rgba8))
    XCTAssertNil(
      ImageLimits.byteCount(width: ImageLimits.maxDimension + 1, height: 1, format: .rgba8))
    XCTAssertEqual(ImageLimits.byteCount(width: 3, height: 2, format: .rgba8), 24)
  }

  /// Catches a tile reply that is not the rectangle the app asked for. The app places the layer
  /// from the rectangle it clipped, so a smaller tile would be stretched and a larger one would
  /// overrun its neighbor. Only an exact match is accepted.
  func testARegionReplyMustBeExactlyTheRectangleAsked() throws {
    let region = ImageExpectation(
      request: 4, source: 2, frame: 0, maxPixel: 400, sourceWidth: 400, sourceHeight: 200,
      byteCap: 512 * 512 * 8, region: (512, 300))

    try region.validate(header(width: 512, height: 300), pixels: Data(count: 512 * 300 * 4))

    for (width, height) in [(511, 300), (512, 299), (100, 50), (513, 300), (512, 301)] {
      XCTAssertThrowsError(
        try region.validate(
          header(width: UInt32(width), height: UInt32(height)),
          pixels: Data(count: width * height * 4)), "\(width) by \(height)")
    }
  }
}
