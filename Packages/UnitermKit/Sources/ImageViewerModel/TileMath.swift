import CoreGraphics
import Foundation
import ImageWire

/// One tile of a decode level. The level is named by the longer side of its decode in pixels.
public struct TileKey: Hashable, Sendable {
  public var level: Int
  public var column: Int
  public var row: Int

  public init(level: Int, column: Int, row: Int) {
    self.level = level
    self.column = column
    self.row = row
  }
}

/// A decode of the image at one scale, which tiles are cut from.
public struct TileLevel: Equatable, Sendable {
  /// The longer side of the decode in pixels.
  public var longerSide: Int
  public var width: Int
  public var height: Int

  /// Level pixels per native pixel.
  public var ratio: Double

  /// The level for an image of `native` size shown at `scale` points per pixel on a display with
  /// `backing` device pixels per point.
  ///
  /// The decode is never larger than native, since a bigger one adds no detail. Between fit and
  /// native it is the smallest power-of-two fraction of native that is not below the device
  /// resolution, so a pinch asks for a new level only when it crosses a boundary.
  public init(native: PixelSize, scale: Double, backing: Double) {
    let device = max(scale * max(backing, 1), 1e-6)
    let fraction: Double

    if device >= 1 {
      fraction = 1
    } else {
      fraction = min(1, pow(2, ceil(log2(device))))
    }

    let longer = max(1, Int((Double(max(native.longer, 1)) * fraction).rounded(.up)))
    let applied = Double(longer) / Double(max(native.longer, 1))

    self.longerSide = longer
    self.ratio = applied
    let size = LevelGeometry.size(
      nativeWidth: native.width, nativeHeight: native.height, longerSide: longer)

    self.width = size.width
    self.height = size.height
  }

  /// The tile's rectangle in level pixels, cut at the level's edge.
  public func rect(of key: TileKey) -> (x: Int, y: Int, width: Int, height: Int) {
    let x = key.column * TileMath.tileSize
    let y = key.row * TileMath.tileSize

    return (
      x, y, min(TileMath.tileSize, max(0, width - x)), min(TileMath.tileSize, max(0, height - y))
    )
  }

  /// The most bytes the whole level takes in eight-bit pixels. The app uses it to refuse a zoom
  /// before the helper starts a decode it could not hold.
  public var bytes: Int {
    let (product, overflow) = width.multipliedReportingOverflow(by: height)

    return overflow ? Int.max : product.multipliedReportingOverflow(by: 4).partialValue
  }
}

public enum TileMath {
  public static let tileSize = 512

  /// How many tiles beyond the pane's edge the cache keeps, so a short pan finds them ready.
  public static let marginTiles = 1

  /// The tiles to hold for `visible`, a rectangle in native pixels, ordered from the middle of the
  /// rectangle outward. The set is the pane's tiles and a ring around them, so its size follows the
  /// pane and not the image.
  public static func wanted(visible: CGRect, in level: TileLevel) -> [TileKey] {
    guard visible.width > 0, visible.height > 0, level.width > 0, level.height > 0 else {
      return []
    }

    let size = Double(tileSize)
    let margin = marginTiles

    let firstColumn = max(0, Int((visible.minX * level.ratio / size).rounded(.down)) - margin)
    let lastColumn = min(
      (level.width - 1) / tileSize, Int((visible.maxX * level.ratio / size).rounded(.down)) + margin
    )
    let firstRow = max(0, Int((visible.minY * level.ratio / size).rounded(.down)) - margin)
    let lastRow = min(
      (level.height - 1) / tileSize,
      Int((visible.maxY * level.ratio / size).rounded(.down)) + margin)

    guard firstColumn <= lastColumn, firstRow <= lastRow else { return [] }

    let centerX = visible.midX * level.ratio / size
    let centerY = visible.midY * level.ratio / size

    var keys: [(key: TileKey, distance: Double)] = []

    for row in firstRow...lastRow {
      for column in firstColumn...lastColumn {
        let dx = Double(column) + 0.5 - centerX
        let dy = Double(row) + 0.5 - centerY

        keys.append((TileKey(level: level.longerSide, column: column, row: row), dx * dx + dy * dy))
      }
    }

    return keys.sorted { $0.distance < $1.distance }.map(\.key)
  }

  /// The most tiles a pane of `pane` points on a display of `backing` holds: the pane's tiles, the
  /// ring around them, and a tile of slack on each side for a pane that straddles tile edges.
  public static func capacity(pane: CGSize, backing: Double) -> Int {
    let size = Double(tileSize)
    let columns = Int((Double(pane.width) * backing / size).rounded(.up)) + 1 + 2 * marginTiles
    let rows = Int((Double(pane.height) * backing / size).rounded(.up)) + 1 + 2 * marginTiles

    return max(1, columns * rows)
  }
}

/// The tiles the app holds, least recently used out first when the count passes its limit.
public struct TileCache<Value> {
  public struct Entry {
    public var value: Value
    public var bytes: Int
    fileprivate var stamp: Int
  }

  public private(set) var entries: [TileKey: Entry] = [:]
  public var capacity: Int

  private var clock = 0

  public init(capacity: Int) {
    self.capacity = max(1, capacity)
  }

  public var count: Int { entries.count }
  public var bytes: Int { entries.values.reduce(0) { $0 + $1.bytes } }

  public func contains(_ key: TileKey) -> Bool {
    entries[key] != nil
  }

  /// Keeps `value` for `key`. Returns what the cache let go to stay within its capacity, and the
  /// entry it replaced.
  public mutating func insert(_ value: Value, bytes: Int, for key: TileKey) -> [Entry] {
    var dropped: [Entry] = []

    if let old = entries.removeValue(forKey: key) { dropped.append(old) }

    clock += 1
    entries[key] = Entry(value: value, bytes: bytes, stamp: clock)

    while entries.count > capacity,
      let oldest = entries.min(by: { $0.value.stamp < $1.value.stamp })?.key
    {
      if let entry = entries.removeValue(forKey: oldest) { dropped.append(entry) }
    }

    return dropped
  }

  /// Lets go of every tile not in `keep`.
  public mutating func retain(_ keep: Set<TileKey>) -> [Entry] {
    var dropped: [Entry] = []

    for key in entries.keys where !keep.contains(key) {
      if let entry = entries.removeValue(forKey: key) { dropped.append(entry) }
    }

    return dropped
  }

  public mutating func removeAll() -> [Entry] {
    defer { entries = [:] }

    return Array(entries.values)
  }
}
