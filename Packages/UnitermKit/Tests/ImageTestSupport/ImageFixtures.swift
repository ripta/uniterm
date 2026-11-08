import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Generates image files in code, so the repo holds no binary fixtures. The fixtures use synthetic
/// content only.
public enum ImageFixtures {
  public typealias Pixel = (r: UInt8, g: UInt8, b: UInt8, a: UInt8)

  public static let red: Pixel = (255, 0, 0, 255)
  public static let green: Pixel = (0, 255, 0, 255)
  public static let blue: Pixel = (0, 0, 255, 255)
  public static let white: Pixel = (255, 255, 255, 255)

  /// A bitmap whose pixel at column `x`, row `y` (row 0 on top) is `fill(x, y)`.
  public static func bitmap(
    width: Int, height: Int, space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!,
    fill: (Int, Int) -> Pixel
  ) -> CGImage {
    var bytes = [UInt8](repeating: 0, count: width * height * 4)

    for y in 0..<height {
      for x in 0..<width {
        let pixel = fill(x, y)
        let at = (y * width + x) * 4
        bytes[at] = pixel.r
        bytes[at + 1] = pixel.g
        bytes[at + 2] = pixel.b
        bytes[at + 3] = pixel.a
      }
    }

    return CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
      bytesPerRow: width * 4, space: space,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false,
      intent: .defaultIntent)!
  }

  /// Red on the top left, green on the top right, blue on the bottom left, white on the bottom
  /// right. The corners tell an orientation apart from any other.
  public static func quadrants(
    width: Int, height: Int, space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
  ) -> CGImage {
    bitmap(width: width, height: height, space: space) { x, y in
      switch (x < width / 2, y < height / 2) {
      case (true, true): return red
      case (false, true): return green
      case (true, false): return blue
      case (false, false): return white
      }
    }
  }

  /// The same four corners as `quadrants`, drawn as four rectangles. A very large image costs four
  /// fills and not a closure call per pixel.
  public static func solidQuadrants(
    width: Int, height: Int, space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
  ) -> CGImage {
    let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

    func fill(_ pixel: Pixel, _ rect: CGRect) {
      context.setFillColor(
        red: CGFloat(pixel.r) / 255, green: CGFloat(pixel.g) / 255, blue: CGFloat(pixel.b) / 255,
        alpha: 1)
      context.fill(rect)
    }

    let halfWidth = CGFloat(width / 2)
    let halfHeight = CGFloat(height / 2)

    fill(red, CGRect(x: 0, y: halfHeight, width: halfWidth, height: CGFloat(height) - halfHeight))
    fill(
      green,
      CGRect(
        x: halfWidth, y: halfHeight, width: CGFloat(width) - halfWidth,
        height: CGFloat(height) - halfHeight))
    fill(blue, CGRect(x: 0, y: 0, width: halfWidth, height: halfHeight))
    fill(white, CGRect(x: halfWidth, y: 0, width: CGFloat(width) - halfWidth, height: halfHeight))

    return context.makeImage()!
  }

  public static func encode(
    _ image: CGImage, as type: UTType, properties: [CFString: Any] = [:]
  ) -> Data {
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!

    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    CGImageDestinationFinalize(destination)

    return data as Data
  }

  public static func png(width: Int = 64, height: Int = 32) -> Data {
    encode(quadrants(width: width, height: height), as: .png)
  }

  /// An animated GIF with one solid frame per color.
  public static func animatedGIF(
    colors: [Pixel], delays: [Double], size: Int = 16
  ) -> Data {
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(
      data, UTType.gif.identifier as CFString, colors.count, nil)!

    CGImageDestinationSetProperties(
      destination,
      [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)

    for (color, delay) in zip(colors, delays) {
      let frame = bitmap(width: size, height: size) { _, _ in color }

      CGImageDestinationAddImage(
        destination, frame,
        [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
    }

    CGImageDestinationFinalize(destination)

    return data as Data
  }

  /// A new empty folder under the temporary directory, removed by `cleanup`.
  public static func makeFolder(_ name: String = "images") throws -> URL {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("uniterm-image-\(UUID().uuidString)", isDirectory: true)
      .resolvingSymlinksInPath()
      .appendingPathComponent(name, isDirectory: true)

    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

    return folder
  }

  @discardableResult
  public static func write(_ data: Data, named name: String, in folder: URL) throws -> URL {
    let file = folder.appendingPathComponent(name)
    try data.write(to: file)

    return file
  }

  /// A file the debug helper turns into a fault when it decodes it. The marker is compiled out of
  /// release builds.
  public static func fault(_ kind: String) -> Data {
    Data("UNITERM-FAULT \(kind)\n".utf8) + Data(repeating: 0, count: 64)
  }

  /// The path of the unsandboxed helper that SwiftPM builds beside the test bundle.
  public static func packageHelper() -> URL {
    let bundle = Bundle.allBundles.first { $0.bundlePath.hasSuffix(".xctest") }
    let products = bundle?.bundleURL.deletingLastPathComponent()

    return (products ?? URL(fileURLWithPath: ".")).appendingPathComponent("ImageDecoderHelper")
  }
}
