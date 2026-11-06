import StatusKit

/// One sentence an applet posts about what it shows now, with its level and its delivery.
///
/// Level. A notice that some of the content is not shown is a warning. A notice that changes
/// nothing on screen, such as a file found at a new path, is info. Lost user work, including work
/// that cannot reach disk, is an error. A message that reports lost work never times out, and a
/// later message that replaces it leaves the unseen-error attention up until the user
/// acknowledges it. A failed load is a warning unless the failure loses user work. The applet
/// states the level, and never works it out from the text.
///
/// Placement. While the pane's content is still on screen, a notice posts once to the status bar.
/// A state that lasts also shows as a segment while it holds. When the pane has nothing else to
/// show, the pane explains itself, and the notice goes to the history only. The wait while
/// something opens stays in the pane. A notice posts once per load, and a new load posts again.
public struct AppletNotice: Hashable, Sendable {
  /// How the notice reaches the user.
  public enum Delivery: Hashable, Sendable {
    /// A turn on the status bar, and an entry in the history.
    case message

    /// An entry in the history only, because the pane already says it.
    case historyOnly
  }

  public var level: StatusLevel
  public var text: String
  public var delivery: Delivery

  /// What makes this notice the same notice on the next refresh. It is the text unless the text
  /// carries a number that grows during a load, as a count of cut rows does.
  public var key: String

  public init(
    _ level: StatusLevel, _ text: String, key: String? = nil, delivery: Delivery = .message
  ) {
    self.level = level
    self.text = text
    self.delivery = delivery
    self.key = key ?? text
  }
}

/// The notices an applet has posted to the status bar for what it shows now, so each is posted
/// once.
///
/// A notice says something about the current load, such as shapes a map skipped or rows a table
/// cut. An applet works out its notices on every refresh. This keeps them from posting again
/// each time. Two notices are the same when their keys match, so a notice whose count grows
/// during a load still posts once. The applet resets it when it loads something new, and a notice
/// that comes back then is posted again.
public struct AppletNotices: Sendable {
  private var posted: Set<String> = []

  public init() {}

  /// The notices of `notices` not yet posted, in order. They count as posted from now on.
  public mutating func unposted(_ notices: [AppletNotice]) -> [AppletNotice] {
    var fresh: [AppletNotice] = []

    for notice in notices where posted.insert(notice.key).inserted {
      fresh.append(notice)
    }

    return fresh
  }

  /// Forgets what was posted, as when a new file loads.
  public mutating func reset() {
    posted = []
  }
}
