import CoreGraphics
import Foundation
import ImageWire

/// Turns a validated helper reply into a bitmap. The color space comes from the closed set of
/// names, never from bytes the helper sent.
enum BitmapFactory {
  static func colorSpace(for space: OutputSpace) -> CGColorSpace? {
    switch space {
    case .sRGB: return CGColorSpace(name: CGColorSpace.sRGB)
    case .displayP3: return CGColorSpace(name: CGColorSpace.displayP3)
    case .extendedLinearDisplayP3: return CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
    case .bt2100PQ: return CGColorSpace(name: CGColorSpace.itur_2100_PQ)
    case .bt2100HLG: return CGColorSpace(name: CGColorSpace.itur_2100_HLG)
    }
  }

  static func bitmapInfo(for format: PixelFormat) -> CGBitmapInfo {
    switch format {
    case .rgba8:
      return CGBitmapInfo(
        rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
      )

    case .rgbaF16:
      return CGBitmapInfo(
        rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
          | CGBitmapInfo.byteOrder16Little.rawValue | CGBitmapInfo.floatComponents.rawValue)
    }
  }

  /// A provider over `pixels` that reads them in place. Bridging a slice to `CFData` copies it, and
  /// the bitmap is the largest thing the pane holds. The provider keeps the data alive until
  /// ImageIO releases it. A buffer small enough for `Data` to keep inline is copied instead,
  /// since its bytes are not at a stable address.
  private static func provider(for pixels: Data) -> CGDataProvider? {
    guard pixels.count > 64 else { return CGDataProvider(data: pixels as CFData) }

    let box = Unmanaged.passRetained(PixelBox(pixels))

    return pixels.withUnsafeBytes { raw -> CGDataProvider? in
      guard let base = raw.baseAddress else {
        box.release()
        return nil
      }

      return CGDataProvider(
        dataInfo: box.toOpaque(), data: base, size: raw.count,
        releaseData: { info, _, _ in
          if let info { Unmanaged<PixelBox>.fromOpaque(info).release() }
        })
    }
  }

  private final class PixelBox {
    let data: Data

    init(_ data: Data) {
      self.data = data
    }
  }

  /// The bitmap for `header` over `pixels`, whose length the caller already checked.
  static func makeImage(_ header: ImageHeader, pixels: Data) -> CGImage? {
    let width = Int(header.width)
    let height = Int(header.height)
    let bytesPerPixel = header.format.bytesPerPixel

    guard let space = colorSpace(for: header.space), let provider = provider(for: pixels)
    else { return nil }

    return CGImage(
      width: width, height: height, bitsPerComponent: bytesPerPixel * 2,
      bitsPerPixel: bytesPerPixel * 8, bytesPerRow: width * bytesPerPixel, space: space,
      bitmapInfo: bitmapInfo(for: header.format), provider: provider, decode: nil,
      shouldInterpolate: true, intent: .defaultIntent)
  }
}
