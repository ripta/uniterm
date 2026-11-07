import Foundation

public struct PixelSize: Equatable, Sendable {
  public var width: Int
  public var height: Int

  public init(width: Int, height: Int) {
    self.width = width
    self.height = height
  }

  public var longer: Int { max(width, height) }
}

/// The size rules for fitting an image to a pane.
public enum FitMath {
  /// The size the image shows at fit: scaled down to fit `available`, and never enlarged past its
  /// own size.
  public static func fitSize(image: PixelSize, in available: PixelSize) -> PixelSize {
    guard image.width > 0, image.height > 0, available.width > 0, available.height > 0 else {
      return PixelSize(width: 0, height: 0)
    }

    let scale = min(
      1.0, Double(available.width) / Double(image.width),
      Double(available.height) / Double(image.height))

    return PixelSize(
      width: max(1, Int((Double(image.width) * scale).rounded())),
      height: max(1, Int((Double(image.height) * scale).rounded())))
  }

  /// The longer side to ask the helper for when the image shows at `displayed` pixels.
  public static func requestedLongerSide(displayed: PixelSize, native: PixelSize) -> Int {
    min(max(displayed.longer, 1), max(native.longer, 1))
  }

  /// True when the bitmap held is too small for `displayed` and the image has more pixels to give.
  public static func needsSharperDecode(
    held: PixelSize, displayed: PixelSize, native: PixelSize
  ) -> Bool {
    displayed.longer > held.longer && held.longer < native.longer
  }
}

/// The frames of an animated image and how long each shows.
public struct AnimationPlan: Equatable, Sendable {
  public let delays: [UInt32]

  public init(delays: [UInt32]) {
    self.delays = delays
  }

  public var frameCount: Int { delays.count }
  public var isAnimated: Bool { delays.count > 1 }

  public func next(after frame: Int) -> Int {
    guard frameCount > 0 else { return 0 }

    return (frame + 1) % frameCount
  }

  /// How long `frame` shows, in milliseconds.
  public func delay(of frame: Int) -> UInt32 {
    delays.indices.contains(frame) ? delays[frame] : 100
  }

  /// The frames to keep while `frame` shows: it and up to `ahead` that follow, wrapping.
  public func window(from frame: Int, ahead: Int) -> [Int] {
    guard frameCount > 0 else { return [] }

    return (0...max(ahead, 0)).map { (frame + $0) % frameCount }
      .reduce(into: [Int]()) { if !$0.contains($1) { $0.append($1) } }
  }
}
