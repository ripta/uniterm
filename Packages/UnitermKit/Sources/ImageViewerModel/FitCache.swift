import Foundation

/// The fit-size decodes a pane keeps beside the one on screen: the image it just left, and the
/// next one in the stepping direction.
///
/// The cache holds at most one of each. Storing a newer one hands back the older one, so the owner
/// can give its memory back to the budget. An entry matches by file name and modification time, so
/// a file replaced on disk never matches the decode of the file it replaced.
public struct FitCache<Value> {
  public struct Entry {
    public var name: String
    public var modified: Double?
    public var value: Value

    public init(name: String, modified: Double?, value: Value) {
      self.name = name
      self.modified = modified
      self.value = value
    }
  }

  public private(set) var previous: Entry?
  public private(set) var prefetched: Entry?

  public init() {}

  public var isEmpty: Bool { previous == nil && prefetched == nil }

  /// Keeps `entry` as the image just left. Returns the entry it replaced.
  public mutating func keepPrevious(_ entry: Entry) -> Entry? {
    defer { previous = entry }

    return previous
  }

  /// Keeps `entry` as the prefetched image. Returns the entry it replaced.
  public mutating func keepPrefetched(_ entry: Entry) -> Entry? {
    defer { prefetched = entry }

    return prefetched
  }

  /// Removes and returns the entry for the image named `name`, if either slot holds it.
  public mutating func take(name: String, modified: Double?) -> Entry? {
    if let held = prefetched, held.name == name, held.modified == modified {
      prefetched = nil
      return held
    }

    if let held = previous, held.name == name, held.modified == modified {
      previous = nil
      return held
    }

    return nil
  }

  public func holds(name: String, modified: Double?) -> Bool {
    (prefetched.map { $0.name == name && $0.modified == modified } ?? false)
      || (previous.map { $0.name == name && $0.modified == modified } ?? false)
  }

  /// Empties the prefetched slot and returns what it held.
  public mutating func dropPrefetched() -> Entry? {
    defer { prefetched = nil }

    return prefetched
  }

  /// Empties the cache and returns what it held.
  public mutating func removeAll() -> [Entry] {
    let all = [previous, prefetched].compactMap { $0 }

    previous = nil
    prefetched = nil

    return all
  }
}

extension FitCache.Entry: Sendable where Value: Sendable {}
extension FitCache: Sendable where Value: Sendable {}
