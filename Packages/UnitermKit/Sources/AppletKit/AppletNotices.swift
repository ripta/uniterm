import StatusKit

/// One sentence an applet posts to the status bar about what it shows now, with its level.
///
/// The level follows one rule across applets. A notice that some of the content is not shown is a
/// warning. A notice that changes nothing on screen, such as a file found at a new path, is info.
/// Lost user work is an error, so it stays until the user sees it.
public struct AppletNotice: Hashable, Sendable {
  public var level: StatusLevel
  public var text: String

  public init(_ level: StatusLevel, _ text: String) {
    self.level = level
    self.text = text
  }
}

/// The notices an applet has posted to the status bar for what it shows now, so each is posted
/// once.
///
/// A notice says something about the current load, such as shapes a map skipped or rows a table
/// cut. An applet works out its notices on every refresh. This keeps them from posting again
/// each time. The applet resets it when it loads something new, and a notice that comes back
/// then is posted again.
public struct AppletNotices: Sendable {
  private var posted: Set<AppletNotice> = []

  public init() {}

  /// The notices of `notices` not yet posted, in order. They count as posted from now on.
  public mutating func unposted(_ notices: [AppletNotice]) -> [AppletNotice] {
    var fresh: [AppletNotice] = []

    for notice in notices where !posted.contains(notice) {
      posted.insert(notice)
      fresh.append(notice)
    }

    return fresh
  }

  /// Forgets what was posted, as when a new file loads.
  public mutating func reset() {
    posted = []
  }
}
