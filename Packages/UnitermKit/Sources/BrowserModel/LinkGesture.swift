import Foundation

/// Whether a link navigation follows a real click, which only the view can see.
///
/// WebKit reports a script's `a.click()` as a followed link, so the navigation type cannot tell a
/// person from a page. The web view notes a real mouse-up here instead. The first link decision
/// within a short bound after it takes the note, and a note is used once. A navigation with no
/// note is a page's own, and a page never opens another app.
///
/// A key press that activates a focused link leaves no note, so it counts as a page's own.
public struct LinkGesture: Sendable, Equatable {
  /// How long a mouse-up stays good. WebKit decides a click's navigation within milliseconds, so
  /// a second is slack for a busy machine, and short enough that a page cannot wait it out.
  public static let bound: TimeInterval = 1

  private var lastMouseUp: Date?

  public init() {}

  public mutating func noteMouseUp(at now: Date) {
    lastMouseUp = now
  }

  /// True when a mouse-up came within the bound before `now`. Either way the note is gone, so the
  /// next decision needs a click of its own. A note from the future, as when the clock stepped
  /// back, never counts.
  public mutating func consume(at now: Date) -> Bool {
    defer { lastMouseUp = nil }

    guard let lastMouseUp else { return false }

    let age = now.timeIntervalSince(lastMouseUp)

    return age >= 0 && age <= Self.bound
  }
}
