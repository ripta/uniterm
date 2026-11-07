import Foundation

/// How a tab notices a content process that no longer answers.
///
/// A user's reload or navigation arms one bound. Any sign of life from the process cancels it, so a
/// slow server never fires it. Nothing arms it in the background. When it runs out, the tab ends
/// the hung content process. A tab the user closes while its page spins gets the same bound, armed
/// at the close. The schedule is injected so a
/// test fires the bound by hand and the production code sleeps for it.
public struct HangPolicy: Sendable {
  public typealias Cancel = @MainActor @Sendable () -> Void
  public typealias Schedule =
    @MainActor @Sendable (Duration, @escaping @MainActor @Sendable () -> Void) -> Cancel

  /// How long a user's reload or navigation may get no answer before the tab replaces its web view.
  /// A policy value with no setting.
  public var bound: Duration

  public var schedule: Schedule

  /// Reads a content process's id and ends it. A test supplies one that signals nothing real.
  var process = WebContentProcess.live

  public init(bound: Duration = .seconds(10), schedule: @escaping Schedule = HangPolicy.sleeping) {
    self.bound = bound
    self.schedule = schedule
  }

  public static let live = HangPolicy()

  /// Runs the action once after the duration, unless the returned closure cancels it first. The
  /// clock stops while the machine sleeps, so a wake never fires the bound before the callbacks
  /// that queued up meanwhile have been heard.
  public static let sleeping: Schedule = { duration, action in
    let task = Task { @MainActor in
      try? await SuspendingClock().sleep(for: duration)

      guard !Task.isCancelled else { return }

      action()
    }

    return { task.cancel() }
  }
}
