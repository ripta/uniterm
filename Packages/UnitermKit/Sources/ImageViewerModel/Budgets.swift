import Dispatch
import Foundation
import os

/// What one image helper may hold, and what all of them may hold together.
public enum ImageHelperPolicy {
  /// A helper whose footprint passes this is killed.
  public static let perHelperCap = 1 << 30

  /// How long one decode may run before the app ends the helper and reports a limit.
  public static let decodeTimeBound: Duration = .seconds(10)
}

/// The app-wide bound on image helpers' memory, kept apart from the REPL helpers' bound.
///
/// A helper asks before it decodes, with an estimate of the footprint the decode adds. A request
/// that would push the total past the limit is refused, unless it fits inside the floor every pane
/// keeps, so a pane opened last can still show its image at fit. The budget never ends another
/// pane's helper to make room.
public final class ImageHelperBudget: Sendable {
  private let state = OSAllocatedUnfairLock(initialState: [Int: Int]())

  public let limit: Int
  public let floor: Int

  public init(limit: Int, floor: Int) {
    self.limit = limit
    self.floor = floor
  }

  /// The smaller of 4 GiB and a quarter of physical memory, with a floor that covers a fit decode
  /// of a large display.
  public static let shared = ImageHelperBudget(
    limit: min(4 << 30, Int(clamping: ProcessInfo.processInfo.physicalMemory) / 4),
    floor: 256 << 20)

  public var used: Int { state.withLock { $0.values.reduce(0, +) } }

  /// Whether `owner` may decode with an estimated footprint of `estimate` bytes.
  public func admits(owner: Int, estimate: Int) -> Bool {
    state.withLock { usage in
      let others = usage.filter { $0.key != owner }.values.reduce(0, +)

      return others + estimate <= limit || estimate <= floor
    }
  }

  /// Records the footprint `owner`'s helper reported.
  public func record(owner: Int, footprint: Int) {
    state.withLock { $0[owner] = footprint }
  }

  public func release(owner: Int) {
    state.withLock { _ = $0.removeValue(forKey: owner) }
  }
}

/// One memory budget for every bitmap image panes hold, together.
///
/// A pane takes a lease and reserves bytes through it for its backdrop and its animation frames. A
/// reservation inside the pane's floor is always granted. The budget therefore bounds the app at
/// its limit plus one floor for each pane beyond it, which keeps a pane from ever being blank for
/// want of memory at fit.
public final class ImageBitmapBudget: Sendable {
  public struct Lease: Sendable, Hashable {
    let id: Int
  }

  private struct State {
    var used = 0
    var nextLease = 0
    var held: [Int: Int] = [:]
  }

  private let state = OSAllocatedUnfairLock(initialState: State())

  public let limit: Int
  public let floor: Int

  public init(limit: Int, floor: Int) {
    self.limit = limit
    self.floor = floor
  }

  /// The smaller of 1 GiB and a quarter of physical memory, with a 256 MiB floor for each pane.
  public static let shared = ImageBitmapBudget(
    limit: min(1 << 30, Int(clamping: ProcessInfo.processInfo.physicalMemory) / 4),
    floor: 256 << 20)

  public var used: Int { state.withLock { $0.used } }

  public func makeLease() -> Lease {
    state.withLock { state in
      state.nextLease += 1
      state.held[state.nextLease] = 0

      return Lease(id: state.nextLease)
    }
  }

  /// Reserves `bytes` for `lease`. False when the budget is full and the lease is past its floor.
  public func reserve(_ bytes: Int, lease: Lease) -> Bool {
    state.withLock { state in
      guard let held = state.held[lease.id] else { return false }

      guard state.used + bytes <= limit || held + bytes <= floor else { return false }

      state.held[lease.id] = held + bytes
      state.used += bytes

      return true
    }
  }

  public func giveBack(_ bytes: Int, lease: Lease) {
    state.withLock { state in
      guard let held = state.held[lease.id] else { return }

      let given = min(bytes, held)
      state.held[lease.id] = held - given
      state.used -= given
    }
  }

  public func held(by lease: Lease) -> Int {
    state.withLock { $0.held[lease.id] ?? 0 }
  }

  public func release(_ lease: Lease) {
    state.withLock { state in
      state.used -= state.held.removeValue(forKey: lease.id) ?? 0
    }
  }
}
