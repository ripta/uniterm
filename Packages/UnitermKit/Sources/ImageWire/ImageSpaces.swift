import Foundation

/// The color spaces a decoded image can arrive in. The set is closed. The app builds a color space
/// from one of these names and never from profile bytes the helper sends.
public enum OutputSpace: UInt8, CaseIterable, Sendable, Equatable {
  case sRGB = 1
  case displayP3 = 2
  case extendedLinearDisplayP3 = 3
  case bt2100PQ = 4
  case bt2100HLG = 5

  /// True for the spaces that carry values beyond the display's standard range.
  public var isHDR: Bool {
    switch self {
    case .sRGB, .displayP3: return false
    case .extendedLinearDisplayP3, .bt2100PQ, .bt2100HLG: return true
    }
  }

  /// The one pixel format the space travels in.
  public var format: PixelFormat { isHDR ? .rgbaF16 : .rgba8 }
}

/// How the pixels of a decoded image are laid out. Both are premultiplied, four channels in the
/// order red, green, blue, alpha, with no row padding.
public enum PixelFormat: UInt8, Sendable, Equatable {
  /// Eight bits per channel.
  case rgba8 = 1

  /// A half-precision float per channel, in little-endian byte order.
  case rgbaF16 = 2

  public var bytesPerPixel: Int {
    switch self {
    case .rgba8: return 4
    case .rgbaF16: return 8
    }
  }
}

/// The limits the app puts on what the helper may send. The helper obeys the same numbers, so a
/// well-behaved decode never meets them.
public enum ImageLimits {
  /// The most pixels along one side of a decoded image.
  public static let maxDimension = 32_768

  /// The most frames an animation may declare.
  public static let maxFrames = 4_096

  /// The most type identifiers the helper may list at hello, and the most bytes in one.
  public static let maxTypes = 1_024
  public static let maxTypeBytes = 128

  /// The most bytes of text in a failure the helper reports.
  public static let maxMessageBytes = 256

  /// The bytes of an image of `width` by `height` in `format`, or nil when a side is zero, a side
  /// is past the maximum, or the product overflows.
  public static func byteCount(width: Int, height: Int, format: PixelFormat) -> Int? {
    guard width > 0, height > 0, width <= maxDimension, height <= maxDimension else { return nil }

    let (row, rowOverflow) = width.multipliedReportingOverflow(by: format.bytesPerPixel)
    let (total, overflow) = row.multipliedReportingOverflow(by: height)

    return rowOverflow || overflow ? nil : total
  }
}
