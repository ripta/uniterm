import Foundation
import ImageIO
import ImageWire
import UniformTypeIdentifiers

/// One image source the helper holds: the mapped file, ImageIO's source over it, and what the
/// header says. Every ImageIO call in the product starts here or in `PixelRenderer`.
final class OpenedImage {
  let mapping: FileMapping
  let source: CGImageSource
  let info: SourceInfo
  let formatName: String
  let hasGainMap: Bool

  /// The EXIF orientation, 1 through 8, of the stored pixels.
  let orientation: Int

  /// The most pixels along a side the helper reads from a header. A header past it is hostile.
  static let maxSourceDimension = 1 << 20

  init(mapping: FileMapping, sourceID: UInt32) throws {
    self.mapping = mapping

    let options: [CFString: Any] = [kCGImageSourceShouldCache: false]

    guard let source = CGImageSourceCreateWithData(mapping.data as CFData, options as CFDictionary),
      let typeID = CGImageSourceGetType(source) as String?
    else {
      throw SourceFailure(kind: .unsupported, text: "uniterm cannot show this file as an image.")
    }

    let type = UTType(typeID)
    formatName = type?.formatName ?? typeID
    self.source = source

    guard CGImageSourceGetStatus(source) == .statusComplete || CGImageSourceGetCount(source) > 0
    else {
      throw SourceFailure(
        kind: .unreadable, text: "This \(formatName) image is damaged and cannot be shown.")
    }

    guard CGImageSourceGetCount(source) > 0,
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
      let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
      width > 0, height > 0, width <= Self.maxSourceDimension, height <= Self.maxSourceDimension
    else {
      throw SourceFailure(
        kind: .unreadable, text: "This \(formatName) image has no usable size.")
    }

    let stored = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
    let orientation = (1...8).contains(stored) ? stored : 1
    self.orientation = orientation
    let swapped = (5...8).contains(orientation)

    hasGainMap =
      CGImageSourceCopyAuxiliaryDataInfoAtIndex(
        source, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil

    info = SourceInfo(
      source: sourceID, width: UInt32(swapped ? height : width),
      height: UInt32(swapped ? width : height), frameDelays: Self.delays(of: source))
  }

  /// The delay of each frame in milliseconds, for a source that animates. A still image, or a
  /// container with several images and no animation, reports one frame.
  private static func delays(of source: CGImageSource) -> [UInt32] {
    let count = min(CGImageSourceGetCount(source), ImageLimits.maxFrames)

    guard count > 1 else { return [0] }

    var delays: [UInt32] = []

    for index in 0..<count {
      guard
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
        let seconds = animationDelay(in: properties)
      else {
        return [0]
      }

      let milliseconds = (seconds * 1000).rounded()
      delays.append(milliseconds <= 10 ? 100 : UInt32(min(milliseconds, 60_000)))
    }

    return delays
  }

  private static func animationDelay(in properties: [CFString: Any]) -> Double? {
    let candidates: [(dictionary: CFString, unclamped: CFString, clamped: CFString)] = [
      (
        kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime,
        kCGImagePropertyGIFDelayTime
      ),
      (
        kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime,
        kCGImagePropertyAPNGDelayTime
      ),
      (
        kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime,
        kCGImagePropertyWebPDelayTime
      ),
      (
        kCGImagePropertyHEICSDictionary, kCGImagePropertyHEICSUnclampedDelayTime,
        kCGImagePropertyHEICSDelayTime
      ),
    ]

    for candidate in candidates {
      guard let dictionary = properties[candidate.dictionary] as? [CFString: Any] else {
        continue
      }

      if let value = (dictionary[candidate.unclamped] as? NSNumber)?.doubleValue
        ?? (dictionary[candidate.clamped] as? NSNumber)?.doubleValue
      {
        return value
      }
    }

    return nil
  }
}
