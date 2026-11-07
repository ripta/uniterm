import Foundation

/// A rectangle of a decode level that a tile request asks for.
public struct TileRegion: Equatable, Sendable {
  /// The longer side of the decode the rectangle is cut from, in pixels.
  public var level: Int
  public var x: Int
  public var y: Int
  public var width: Int
  public var height: Int

  public init(level: Int, x: Int, y: Int, width: Int, height: Int) {
    self.level = level
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }
}

/// One decode the pane asks its helper for.
public struct DecodeRequest: Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    /// The image the user is looking at, at the size it shows.
    case still

    /// The next frame of an animation. It yields to a still.
    case frame

    /// The next image in the stepping direction, at fit size, while nothing else waits. It yields
    /// to every other kind.
    case prefetch

    /// A tile of the zoomed image. It yields to a still, and replaces a waiting frame or prefetch.
    case tile
  }

  public var id: UInt32
  public var source: UInt32
  public var maxPixel: Int
  public var frame: Int
  public var kind: Kind

  /// The rectangle a tile request asks for. Nil for every other kind.
  public var region: TileRegion?

  public init(
    id: UInt32, source: UInt32, maxPixel: Int, frame: Int, kind: Kind, region: TileRegion? = nil
  ) {
    self.id = id
    self.source = source
    self.maxPixel = maxPixel
    self.frame = frame
    self.kind = kind
    self.region = region
  }
}

/// Latest-wins scheduling for one helper. At most one decode is in flight and one waits. A decode
/// cannot be cancelled without killing the helper, so a newer request replaces the waiting one and
/// never the one in flight.
///
/// A frame request never replaces a waiting still, so an animation cannot starve a resize or a
/// step. A frame request that finds a still waiting is dropped, and the player asks again.
///
/// A tile request never replaces a waiting still, so a step or a resize is not held up by the tiles
/// of the image the pane is leaving. It replaces any other waiting request, so the newest viewport
/// wins and tiles for a viewport the user has left are never sent.
///
/// A prefetch takes the idle slot only. It waits behind the decode in flight when nothing else
/// waits, and any other request replaces it. A prefetch that finds another request waiting is
/// dropped. A pane zoomed past fit never prefetches, so the owner sets `isZoomedPastFit` and the
/// scheduler refuses prefetches while it holds.
public struct RequestScheduler: Sendable, Equatable {
  public private(set) var inFlight: DecodeRequest?
  public private(set) var pending: DecodeRequest?

  /// Whether the pane shows more than a fit. Turning it on drops a waiting prefetch.
  public var isZoomedPastFit = false {
    didSet {
      if isZoomedPastFit, pending?.kind == .prefetch { pending = nil }
    }
  }

  public init() {}

  /// Offers a request. Returns the request to send now, or nil when it waits or is dropped.
  public mutating func submit(_ request: DecodeRequest) -> DecodeRequest? {
    if request.kind == .prefetch {
      guard !isZoomedPastFit else { return nil }

      guard inFlight != nil else {
        inFlight = request
        return request
      }

      if pending == nil { pending = request }

      return nil
    }

    guard inFlight != nil else {
      inFlight = request
      return request
    }

    if request.kind == .frame, pending?.kind == .still { return nil }

    if request.kind == .tile, pending?.kind == .still { return nil }

    pending = request

    return nil
  }

  /// The decode in flight is done, answered or failed. Returns the waiting request to send next.
  public mutating func finish() -> DecodeRequest? {
    inFlight = pending
    pending = nil

    return inFlight
  }

  /// Forgets both requests, as when the helper dies.
  public mutating func reset() {
    inFlight = nil
    pending = nil
  }

  public var isIdle: Bool { inFlight == nil && pending == nil }
}
