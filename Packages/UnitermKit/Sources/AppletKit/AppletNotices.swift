/// The notices an applet has posted to the status bar for what it shows now, so each is posted
/// once.
///
/// A notice says something about the current load, such as shapes a map skipped or rows a table
/// cut. An applet works out its notices on every refresh. This keeps them from posting again
/// each time. The applet resets it when it loads something new, and a notice that comes back
/// then is posted again.
public struct AppletNotices: Sendable {
  private var posted: Set<String> = []

  public init() {}

  /// The lines of `lines` not yet posted, in order. They count as posted from now on.
  public mutating func unposted(_ lines: [String]) -> [String] {
    var fresh: [String] = []

    for line in lines where !posted.contains(line) {
      posted.insert(line)
      fresh.append(line)
    }

    return fresh
  }

  /// Forgets what was posted, as when a new file loads.
  public mutating func reset() {
    posted = []
  }
}
