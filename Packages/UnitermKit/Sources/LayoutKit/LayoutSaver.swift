import Foundation

/// Runs a closure after a delay and returns a way to cancel it. It matches the shape of the status
/// center's scheduler, so a test fires wakeups by hand.
public typealias LayoutScheduler =
  @MainActor (_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) ->
  @MainActor () ->
  Void

/// Saves the layout after a short quiet period, and at once when asked.
///
/// Every layout change restarts the wait, so a burst of changes writes once. A stream of changes
/// that never goes quiet still writes once the maximum wait has passed since the first of them.
///
/// The caller asks for an immediate save on quit, which also drops any wait still pending.
///
/// Saving stays off until the caller turns it on, so a half-restored layout never replaces the
/// file.
///
/// The snapshot is taken on the main actor, where the layout lives. The write encodes and stores
/// it on a background queue, so a layout with tens of thousands of tabs never stalls the windows.
/// One write runs at a time. A snapshot taken while a write runs replaces the one waiting behind
/// it, so only the newest waits. Quit calls `waitForWrites` to be sure the last layout is on disk.
@MainActor
public final class LayoutSaver {
  public static let defaultScheduler: LayoutScheduler = { delay, action in
    let task = Task { @MainActor in
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled else { return }

      action()
    }

    return { task.cancel() }
  }

  /// How long the layout must stay unchanged before it is written.
  public let debounce: TimeInterval

  /// The longest a change waits for a save, however many changes follow it.
  public let maximumWait: TimeInterval

  private let scheduler: LayoutScheduler
  private let snapshot: @MainActor () -> SavedLayout
  private let onFailure: @MainActor (any Error) -> Void
  private let writer: LayoutWriteQueue
  private var cancelPending: (@MainActor () -> Void)?
  private var cancelDeadline: (@MainActor () -> Void)?
  private var lastFailure: String?

  public private(set) var isEnabled = false

  /// `snapshot` reads the layout now, on the main actor. `write` stores it, on a background
  /// queue. A failed write goes to `onFailure`, once for each distinct failure until a write
  /// succeeds.
  public init(
    debounce: TimeInterval = 1, maximumWait: TimeInterval = 10,
    scheduler: @escaping LayoutScheduler = LayoutSaver.defaultScheduler,
    snapshot: @escaping @MainActor () -> SavedLayout,
    write: @escaping @Sendable (SavedLayout) throws -> Void,
    onFailure: @escaping @MainActor (any Error) -> Void
  ) {
    self.debounce = debounce
    self.maximumWait = maximumWait
    self.scheduler = scheduler
    self.snapshot = snapshot
    self.onFailure = onFailure
    writer = LayoutWriteQueue(write: write)
  }

  public func enable() {
    isEnabled = true
  }

  /// Turns saving off and drops a pending save, along with a layout still waiting to be written.
  /// A write already running finishes. Nothing else is written afterwards.
  public func disable() {
    isEnabled = false
    cancelWaits()
    writer.dropWaiting()
  }

  private func cancelWaits() {
    cancelPending?()
    cancelPending = nil
    cancelDeadline?()
    cancelDeadline = nil
  }

  /// The layout changed. A save follows once the quiet period passes.
  public func layoutDidChange() {
    guard isEnabled else { return }

    cancelPending?()
    cancelPending = scheduler(debounce) { [weak self] in
      self?.saveNow()
    }

    if cancelDeadline == nil {
      cancelDeadline = scheduler(maximumWait) { [weak self] in
        self?.saveNow()
      }
    }
  }

  /// Starts a write of the layout now. A save pending from a change is dropped, since this one
  /// covers it. The write finishes on its own time. `waitForWrites` waits for it.
  public func saveNow() {
    guard isEnabled else { return }

    cancelWaits()
    writer.submit(snapshot()) { [weak self] in
      DispatchQueue.main.async { MainActor.assumeIsolated { self?.reportFinishedWrites() } }
    }
  }

  /// Blocks until every write started so far has finished, and reports their failures. Quit uses it
  /// so the last layout is on disk before the lock is let go. The wait covers the write in flight
  /// and at most one behind it, so its length is at most two writes of the layout.
  public func waitForWrites() {
    writer.waitUntilIdle()
    reportFinishedWrites()
  }

  private func reportFinishedWrites() {
    for outcome in writer.takeOutcomes() {
      guard let error = outcome else {
        lastFailure = nil
        continue
      }

      let text = "\(error)"

      if text != lastFailure {
        lastFailure = text
        onFailure(error)
      }
    }
  }
}

/// Runs the layout writes one at a time on a background queue, and keeps only the newest layout
/// waiting behind the one being written.
///
/// Its state sits behind one condition lock. The writer thread and the main actor both touch it.
private final class LayoutWriteQueue: @unchecked Sendable {
  private let write: @Sendable (SavedLayout) throws -> Void
  private let queue = DispatchQueue(label: "dev.uniterm.layout-save", qos: .userInitiated)
  private let condition = NSCondition()

  private var waiting: SavedLayout?
  private var running = false
  private var finished: [(any Error)?] = []

  init(write: @escaping @Sendable (SavedLayout) throws -> Void) {
    self.write = write
  }

  /// Queues `layout` behind the write in flight, replacing any layout already waiting. `finished`
  /// is called from the writer thread after each write.
  func submit(_ layout: SavedLayout, finished notify: @escaping @Sendable () -> Void) {
    condition.lock()
    defer { condition.unlock() }

    waiting = layout

    guard !running else { return }

    running = true
    queue.async { [self] in drain(notify) }
  }

  /// The outcome of each write since the last call, oldest first. A nil is a write that worked.
  func takeOutcomes() -> [(any Error)?] {
    condition.lock()
    defer { condition.unlock() }

    let taken = finished
    finished = []
    return taken
  }

  /// Forgets the layout waiting behind the write in flight, if there is one.
  func dropWaiting() {
    condition.lock()
    waiting = nil
    condition.unlock()
  }

  func waitUntilIdle() {
    condition.lock()
    defer { condition.unlock() }

    while running { condition.wait() }
  }

  private func drain(_ notify: @Sendable () -> Void) {
    while true {
      condition.lock()

      guard let layout = waiting else {
        running = false
        condition.broadcast()
        condition.unlock()
        return
      }

      waiting = nil
      condition.unlock()

      let outcome: (any Error)?

      do {
        try write(layout)
        outcome = nil
      } catch {
        outcome = error
      }

      condition.lock()
      finished.append(outcome)
      condition.unlock()

      notify()
    }
  }
}
