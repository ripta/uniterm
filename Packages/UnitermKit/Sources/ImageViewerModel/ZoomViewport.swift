import CoreGraphics
import Foundation
import ImageWire

extension SourceInfo {
  /// Points per pixel at the size Preview shows the image. A file that declares no resolution shows
  /// at 72 dots per inch, so one pixel is one point. A Retina screenshot at 144 dots per inch shows
  /// at half its pixel size.
  public var actualScale: Double {
    guard dpiX > 0, dpiY > 0 else { return 1 }

    return 72.0 / Double(dpiX)
  }
}

/// Where the image sits in the pane, and how large it shows.
///
/// The scale is in points per image pixel. Fit is the largest scale that shows the whole image,
/// never past actual size. The center is the image pixel under the middle of the pane. While the
/// image is smaller than the pane along an axis, it stays centered on that axis. While it is larger,
/// the pane never shows space past the image edge, so a pan cannot reveal blank edges.
public struct ZoomViewport: Equatable, Sendable {
  public private(set) var native: PixelSize
  public private(set) var pane: CGSize
  public private(set) var actualScale: Double
  public private(set) var scale: Double
  public private(set) var centerX: Double
  public private(set) var centerY: Double
  public private(set) var isFit: Bool

  /// The most device pixels one image pixel may cover. It bounds how far in the user can go.
  public static let maxDevicePixelsPerPixel = 32.0

  public init(native: PixelSize, pane: CGSize, actualScale: Double) {
    self.native = native
    self.pane = pane
    self.actualScale = actualScale > 0 ? actualScale : 1
    self.scale = 1
    self.centerX = Double(native.width) / 2
    self.centerY = Double(native.height) / 2
    self.isFit = true

    scale = fitScale
  }

  /// The scale that shows the whole image, and never more than actual size.
  public var fitScale: Double {
    guard native.width > 0, native.height > 0, pane.width > 0, pane.height > 0 else {
      return actualScale
    }

    return min(
      actualScale, Double(pane.width) / Double(native.width),
      Double(pane.height) / Double(native.height))
  }

  public func maxScale(backing: Double) -> Double {
    max(Self.maxDevicePixelsPerPixel / max(backing, 1), fitScale)
  }

  /// The image size at the current scale, in points.
  public var imageSize: CGSize {
    CGSize(width: Double(native.width) * scale, height: Double(native.height) * scale)
  }

  /// The top left corner of the image in the pane, in points.
  public var origin: CGPoint {
    let size = imageSize

    return CGPoint(
      x: size.width <= pane.width
        ? (pane.width - size.width) / 2 : pane.width / 2 - centerX * scale,
      y: size.height <= pane.height
        ? (pane.height - size.height) / 2 : pane.height / 2 - centerY * scale)
  }

  /// The part of the image the pane shows, in image pixels.
  public var visibleRect: CGRect {
    let origin = origin
    let size = imageSize

    let minX = max(0, -origin.x / scale)
    let minY = max(0, -origin.y / scale)
    let maxX = min(Double(native.width), (pane.width - origin.x) / scale)
    let maxY = min(Double(native.height), (pane.height - origin.y) / scale)

    guard maxX > minX, maxY > minY, size.width > 0, size.height > 0 else { return .zero }

    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
  }

  public mutating func resize(pane newPane: CGSize) {
    pane = newPane

    if isFit {
      scale = fitScale
    } else if scale <= fitScale {
      showFit()
    }

    clampCenter()
  }

  public mutating func showFit() {
    isFit = true
    scale = fitScale
    centerX = Double(native.width) / 2
    centerY = Double(native.height) / 2
  }

  /// Sets the scale, keeping the image point under `anchor` where it is. A scale at or below fit
  /// shows fit.
  public mutating func setScale(_ target: Double, anchor: CGPoint? = nil, backing: Double) {
    let fit = fitScale
    let clamped = min(max(target, fit), maxScale(backing: backing))

    guard clamped > fit * 1.0001 else {
      showFit()
      return
    }

    let around = anchor ?? CGPoint(x: pane.width / 2, y: pane.height / 2)
    let originBefore = origin
    let pointX = (around.x - originBefore.x) / scale
    let pointY = (around.y - originBefore.y) / scale

    isFit = false
    scale = clamped
    centerX = pointX - (around.x - pane.width / 2) / clamped
    centerY = pointY - (around.y - pane.height / 2) / clamped
    clampCenter()
  }

  public mutating func zoom(by factor: Double, anchor: CGPoint? = nil, backing: Double) {
    setScale(scale * factor, anchor: anchor, backing: backing)
  }

  /// The scale a zoom command moves to. Each step doubles or halves the scale, and stops at actual
  /// size when the step would pass it, so 100 percent is always one command away.
  public func steppedScale(zoomingIn: Bool) -> Double {
    let target = zoomingIn ? scale * 2 : scale / 2
    let crosses =
      zoomingIn
      ? (scale < actualScale && target > actualScale)
      : (scale > actualScale && target < actualScale)

    return crosses ? actualScale : target
  }

  public mutating func showActualSize(anchor: CGPoint? = nil, backing: Double) {
    setScale(actualScale, anchor: anchor, backing: backing)
  }

  /// Moves the image under the pane by `delta` points, as a drag or a scroll does.
  public mutating func pan(byPoints delta: CGSize) {
    guard !isFit else { return }

    centerX -= Double(delta.width) / scale
    centerY -= Double(delta.height) / scale
    clampCenter()
  }

  private mutating func clampCenter() {
    centerX = Self.clamp(
      centerX, extent: Double(native.width), pane: Double(pane.width), scale: scale)
    centerY = Self.clamp(
      centerY, extent: Double(native.height), pane: Double(pane.height), scale: scale)
  }

  private static func clamp(_ value: Double, extent: Double, pane: Double, scale: Double) -> Double
  {
    let half = pane / 2 / scale

    guard extent > 2 * half else { return extent / 2 }

    return min(max(value, half), extent - half)
  }
}
