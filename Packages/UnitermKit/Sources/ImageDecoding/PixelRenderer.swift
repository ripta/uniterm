import CoreGraphics
import Foundation
import ImageIO
import ImageWire

/// A decoded image in one of the named output spaces.
struct RenderedImage {
  var width: Int
  var height: Int
  var space: OutputSpace
  var pixels: Data
}

/// Decodes one frame downsampled to a pixel size and converts it into a named output space.
enum PixelRenderer {
  /// The output space for an image that decoded in `colorSpace`.
  ///
  /// An HDR space keeps its range in extended-linear Display P3. A space other than sRGB goes to
  /// Display P3, which the Mac's displays show in full. sRGB and unknown spaces stay sRGB.
  static func outputSpace(for colorSpace: CGColorSpace?, hdr: Bool) -> OutputSpace {
    guard let colorSpace else { return .sRGB }

    if hdr || CGColorSpaceUsesITUR_2100TF(colorSpace) || CGColorSpaceUsesExtendedRange(colorSpace) {
      return .extendedLinearDisplayP3
    }

    if let name = colorSpace.name as String?, name == (CGColorSpace.sRGB as String) {
      return .sRGB
    }

    if colorSpace.model == .monochrome { return .sRGB }

    return .displayP3
  }

  static func colorSpace(for space: OutputSpace) -> CGColorSpace? {
    switch space {
    case .sRGB: return CGColorSpace(name: CGColorSpace.sRGB)
    case .displayP3: return CGColorSpace(name: CGColorSpace.displayP3)
    case .extendedLinearDisplayP3: return CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
    case .bt2100PQ: return CGColorSpace(name: CGColorSpace.itur_2100_PQ)
    case .bt2100HLG: return CGColorSpace(name: CGColorSpace.itur_2100_HLG)
    }
  }

  static func bitmapInfo(for format: PixelFormat) -> UInt32 {
    switch format {
    case .rgba8:
      return CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

    case .rgbaF16:
      return CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
        | CGBitmapInfo.floatComponents.rawValue
    }
  }

  /// Decodes `frame` so the longer side is at most `maxPixel`, or native when it is zero.
  ///
  /// A source with a gain map decodes whole and is scaled by drawing. `fullDecode` forces that path
  /// for a source without one, which is how the tests reach it.
  static func render(
    _ image: OpenedImage, frame: Int, maxPixel: Int, fullDecode: Bool? = nil
  ) throws -> RenderedImage {
    let native = max(Int(image.info.width), Int(image.info.height))
    let target = min(maxPixel > 0 ? min(maxPixel, native) : native, ImageLimits.maxDimension)

    let hdrSource = fullDecode ?? image.hasGainMap

    let decoded: CGImage

    if hdrSource {
      guard
        let full = CGImageSourceCreateImageAtIndex(
          image.source, frame,
          [kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR] as CFDictionary)
      else {
        throw failure(image)
      }

      decoded = full
    } else {
      let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: target,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceShouldAllowFloat: true,
      ]

      guard
        let thumbnail = CGImageSourceCreateThumbnailAtIndex(
          image.source, frame, options as CFDictionary)
      else {
        throw failure(image)
      }

      decoded = thumbnail
    }

    let space = outputSpace(for: decoded.colorSpace, hdr: hdrSource)

    var width = decoded.width
    var height = decoded.height
    var orientation = 1

    if hdrSource {
      // The whole-image path returns the stored pixels. Only a thumbnail applies the orientation.
      orientation = image.orientation

      if (5...8).contains(orientation) { swap(&width, &height) }

      let longer = max(width, height)

      if longer > target, target > 0 {
        width = max(1, Int((Double(width) * Double(target) / Double(longer)).rounded()))
        height = max(1, Int((Double(height) * Double(target) / Double(longer)).rounded()))
      }
    }

    return try draw(
      decoded, width: width, height: height, space: space, orientation: orientation)
  }

  /// The transform that turns a stored image of `width` by `height` into its upright form, with
  /// the origin at the bottom left. It follows the EXIF table: 2 mirrors horizontally, 3 turns
  /// half way, 4 mirrors vertically, 5 transposes, 6 turns clockwise, 7 transverses, and 8 turns
  /// counterclockwise.
  static func uprightTransform(orientation: Int, width: Int, height: Int) -> CGAffineTransform {
    let w = CGFloat(width)
    let h = CGFloat(height)

    // Each case maps top-left-origin coordinates (u, v) of the stored image to those of the
    // upright one: u' = a*u + c*v + tx, v' = b*u + d*v + ty.
    let upright: CGAffineTransform

    switch orientation {
    case 2: upright = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)
    case 3: upright = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
    case 4: upright = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
    case 5: upright = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
    case 6: upright = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
    case 7: upright = CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: h, ty: w)
    case 8: upright = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
    default: return .identity
    }

    let swapped = (5...8).contains(orientation)
    let uprightHeight = swapped ? w : h

    let toTopLeft = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
    let toBottomLeft = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: uprightHeight)

    return toTopLeft.concatenating(upright).concatenating(toBottomLeft)
  }

  /// Draws `source` into a fresh buffer of `width` by `height` in `space`.
  static func draw(
    _ source: CGImage, width: Int, height: Int, space: OutputSpace, orientation: Int = 1
  ) throws -> RenderedImage {
    let format = space.format

    guard let count = ImageLimits.byteCount(width: width, height: height, format: format),
      let colorSpace = colorSpace(for: space)
    else {
      throw SourceFailure(
        kind: .limit, text: "This image is larger than the decoder will produce.")
    }

    var pixels = Data(count: count)
    let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
      guard
        let context = CGContext(
          data: raw.baseAddress, width: width, height: height,
          bitsPerComponent: format == .rgba8 ? 8 : 16,
          bytesPerRow: width * format.bytesPerPixel, space: colorSpace,
          bitmapInfo: bitmapInfo(for: format))
      else { return false }

      context.interpolationQuality = .high

      let swapped = (5...8).contains(orientation)
      let uprightWidth = CGFloat(swapped ? source.height : source.width)
      let uprightHeight = CGFloat(swapped ? source.width : source.height)

      context.scaleBy(x: CGFloat(width) / uprightWidth, y: CGFloat(height) / uprightHeight)
      context.concatenate(
        uprightTransform(orientation: orientation, width: source.width, height: source.height))
      context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))

      return true
    }

    guard drawn else {
      throw SourceFailure(
        kind: .limit, text: "This image is larger than the decoder can draw.")
    }

    return RenderedImage(width: width, height: height, space: space, pixels: pixels)
  }

  private static func failure(_ image: OpenedImage) -> SourceFailure {
    SourceFailure(
      kind: .unreadable, text: "This \(image.formatName) image could not be decoded.")
  }
}
