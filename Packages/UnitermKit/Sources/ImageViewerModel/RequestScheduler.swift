import Foundation

/// One decode the pane asks its helper for.
public struct DecodeRequest: Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    /// The image the user is looking at, at the size it shows.
    case still

    /// The next frame of an animation. It yields to a still.
    case frame
  }

  public var id: UInt32
  public var source: UInt32
  public var maxPixel: Int
  public var frame: Int
  public var kind: Kind

  public init(id: UInt32, source: UInt32, maxPixel: Int, frame: Int, kind: Kind) {
    self.id = id
    self.source = source
    self.maxPixel = maxPixel
    self.frame = frame
    self.kind = kind
  }
}

/// Latest-wins scheduling for one helper. At most one decode is in flight and one waits. A decode
/// cannot be cancelled without killing the helper, so a newer request replaces the waiting one and
/// never the one in flight.
///
/// A frame request never replaces a waiting still, so an animation cannot starve a resize or a
/// step. A frame request that finds a still waiting is dropped, and the player asks again.
public struct RequestScheduler: Sendable, Equatable {
  public private(set) var inFlight: DecodeRequest?
  public private(set) var pending: DecodeRequest?

  public init() {}

  /// Offers a request. Returns the request to send now, or nil when it waits or is dropped.
  public mutating func submit(_ request: DecodeRequest) -> DecodeRequest? {
    guard inFlight != nil else {
      inFlight = request
      return request
    }

    if request.kind == .frame, pending?.kind == .still { return nil }

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
