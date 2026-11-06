import Foundation

/// The pure model behind the status bar message area.
///
/// Every method takes the current time, so a test drives it with a fake clock. The queue never
/// reads a clock itself.
public struct StatusQueue: Sendable {
  private struct Pending: Sendable {
    var message: StatusMessage

    /// Older errors folded into this one, oldest first. They are kept whole, so a pane close can
    /// give back the ones that did not come from the closing pane.
    var folded: [StatusMessage]
  }

  public let policy: StatusPolicy

  public private(set) var current: StatusDisplay?
  public private(set) var history: [StatusMessage] = []

  /// True from the time an error is posted until the user opens the history.
  public private(set) var hasUnseenError = false

  private var pending: [Pending] = []
  private var shownAt: TimeInterval = 0
  private var nextID: UInt64 = 1

  public init(policy: StatusPolicy = .standard) {
    self.policy = policy
  }

  public var pendingCount: Int { pending.count }

  @discardableResult
  public mutating func post(
    level: StatusLevel, source: StatusSource, text: String, at now: TimeInterval
  ) -> StatusMessage {
    let message = admit(level: level, source: source, text: text, at: now)

    if level == .error {
      hasUnseenError = true
    }

    pending.append(Pending(message: message, folded: []))
    advance(at: now)
    return message
  }

  /// Admits a message to the history only. It takes no turn on the bar and raises no unseen
  /// signal. An applet records this way when its own pane already says the same thing.
  @discardableResult
  public mutating func record(
    level: StatusLevel, source: StatusSource, text: String, at now: TimeInterval
  ) -> StatusMessage {
    admit(level: level, source: source, text: text, at: now)
  }

  /// Applies whatever the passage of time allows. Returns true when the displayed message changed.
  @discardableResult
  public mutating func advance(at now: TimeInterval) -> Bool {
    guard let shown = current else {
      guard !pending.isEmpty else { return false }

      show(at: now)
      return true
    }

    let elapsed = now - shownAt

    if !pending.isEmpty {
      guard elapsed >= policy.minimumDwell else { return false }

      show(at: now)
      return true
    }

    if shown.message.level != .error, elapsed >= policy.idleTimeout {
      current = nil
      return true
    }

    return false
  }

  /// Clears an error that is on the bar. Returns true when something was cleared.
  @discardableResult
  public mutating func dismissCurrent(at now: TimeInterval) -> Bool {
    guard let shown = current, shown.message.level == .error else { return false }

    current = nil
    advance(at: now)
    return true
  }

  /// Drops the queued messages that a closed pane posted. They stay in the history. A message of
  /// that pane that is already on the bar stays until its normal turn ends, since the user may
  /// not have read it yet. Returns true when something left the queue.
  ///
  /// Errors from other sources that were folded into a dropped error are queued again, so the
  /// close never hides an error from a pane that is still open.
  @discardableResult
  public mutating func removePending(fromPane id: UInt64) -> Bool {
    var changed = false
    var kept: [Pending] = []

    for entry in pending {
      let survivors = entry.folded.filter { $0.source.paneID != id }

      if entry.message.source.paneID == id {
        changed = true
        kept += survivors.map { Pending(message: $0, folded: []) }
      } else if survivors.count != entry.folded.count {
        changed = true
        var trimmed = entry
        trimmed.folded = survivors
        kept.append(trimmed)
      } else {
        kept.append(entry)
      }
    }

    pending = kept
    return changed
  }

  public mutating func markHistorySeen() {
    hasUnseenError = false
  }

  /// The time at which `advance` next has something to do, or nil when nothing is scheduled.
  public func nextWake() -> TimeInterval? {
    guard let shown = current else { return nil }

    if !pending.isEmpty {
      return shownAt + policy.minimumDwell
    }

    if shown.message.level != .error {
      return shownAt + policy.idleTimeout
    }

    return nil
  }

  private mutating func admit(
    level: StatusLevel, source: StatusSource, text: String, at now: TimeInterval
  ) -> StatusMessage {
    let message = StatusMessage(
      id: nextID, level: level, source: source, text: text, postedAt: now)
    nextID += 1

    history.append(message)
    if history.count > policy.historyLimit {
      history.removeFirst(history.count - policy.historyLimit)
    }

    return message
  }

  private mutating func show(at now: TimeInterval) {
    normalizePending()

    let next = pending.removeFirst()
    current = StatusDisplay(message: next.message, collapsedErrors: next.folded.count)
    shownAt = now
  }

  /// Folds a backlog of errors into the newest one, then skips older non-error messages when the
  /// backlog is long. An error is never dropped, only counted.
  private mutating func normalizePending() {
    let errorIndexes = pending.indices.filter { pending[$0].message.level == .error }

    if errorIndexes.count > 1, let newest = errorIndexes.last {
      for index in errorIndexes.dropLast() {
        pending[newest].folded += pending[index].folded + [pending[index].message]
      }

      let older = Set(errorIndexes.dropLast())
      pending = pending.enumerated().filter { !older.contains($0.offset) }.map(\.element)
    }

    if pending.count > policy.backlogLimit {
      let lastIndex = pending.count - 1
      pending = pending.enumerated().filter {
        $0.element.message.level == .error || $0.offset == lastIndex
      }.map(\.element)
    }
  }
}
