import Foundation

/// Reads the time for a status center. Tests inject a fake.
public protocol StatusClock: Sendable {
  var now: TimeInterval { get }
}

public struct SystemStatusClock: StatusClock {
  public init() {}

  public var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

/// Runs an action after a delay and returns a closure that cancels it.
public typealias StatusScheduler =
  @MainActor (_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) ->
  @MainActor () ->
  Void

/// The window's message queue. It owns a `StatusQueue`, reads the clock, and wakes itself when the
/// model has something to do.
@MainActor
public final class StatusCenter {
  public private(set) var queue: StatusQueue

  private let clock: any StatusClock
  private let scheduler: StatusScheduler
  private var cancelWake: (@MainActor () -> Void)?
  private var observers: [UUID: @MainActor () -> Void] = [:]

  public init(
    policy: StatusPolicy = .standard,
    clock: any StatusClock = SystemStatusClock(),
    scheduler: @escaping StatusScheduler = StatusCenter.defaultScheduler
  ) {
    self.queue = StatusQueue(policy: policy)
    self.clock = clock
    self.scheduler = scheduler
  }

  public static let defaultScheduler: StatusScheduler = { delay, action in
    let task = Task { @MainActor in
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled else { return }

      action()
    }
    return { task.cancel() }
  }

  public var display: StatusDisplay? { queue.current }
  public var history: [StatusMessage] { queue.history }
  public var hasUnseenError: Bool { queue.hasUnseenError }

  public func post(level: StatusLevel, source: StatusSource, text: String) {
    queue.post(level: level, source: source, text: text, at: clock.now)
    didChange()
  }

  /// Records a message in the history without showing it. See `StatusQueue.record`.
  public func record(level: StatusLevel, source: StatusSource, text: String) {
    queue.record(level: level, source: source, text: text, at: clock.now)
    didChange()
  }

  public func dismissCurrent() {
    if queue.dismissCurrent(at: clock.now) {
      didChange()
    }
  }

  /// A pane closed. Its queued messages leave the bar and stay in the history.
  public func paneClosed(id: UInt64) {
    if queue.removePending(fromPane: id) {
      didChange()
    }
  }

  public func markHistorySeen() {
    queue.markHistorySeen()
    didChange()
  }

  @discardableResult
  public func addObserver(_ handler: @escaping @MainActor () -> Void) -> UUID {
    let id = UUID()
    observers[id] = handler
    return id
  }

  public func removeObserver(_ id: UUID) {
    observers[id] = nil
  }

  private func wake() {
    cancelWake = nil
    queue.advance(at: clock.now)
    didChange()
  }

  private func didChange() {
    cancelWake?()
    cancelWake = nil

    if let deadline = queue.nextWake() {
      let delay = max(0, deadline - clock.now)
      cancelWake = scheduler(delay) { [weak self] in self?.wake() }
    }

    for handler in observers.values {
      handler()
    }
  }
}
