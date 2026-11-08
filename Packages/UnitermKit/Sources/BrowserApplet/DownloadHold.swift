import Foundation

/// The downloads a page started without a click of the user's, counted for one load, and the
/// policy decisions held while the pane asks whether the page may start more.
///
/// A policy decision may wait, unlike a request for a new window, so the fourth such download
/// keeps its decision handler here. The handler answers `true` to start the download and `false` to
/// cancel it at the decision. A cancel at the decision never meets the hazard of cancelling a
/// download that has not received its first byte.
struct DownloadHold {
  enum Phase: Equatable {
    /// The page has not passed the free limit since its last load.
    case counting

    /// The page passed the limit and no question was asked yet, since another one was up.
    case waiting

    /// The question about this page is up.
    case asking

    /// The user let the page download until its next load.
    case granted

    /// The user refused, so every further download from the page is cancelled until its next load.
    case refused
  }

  /// One held decision.
  struct Held {
    /// The file's name when the page or the server named one.
    var name: String?

    var resolve: @MainActor (Bool) -> Void
  }

  /// How many downloads a page may start per load before the pane asks. A policy value with no
  /// setting.
  static let freeLimit = 3

  /// The most decisions held at once. It guards memory. A decision over it is cancelled.
  static let heldLimit = 16

  private(set) var phase = Phase.counting
  private(set) var held: [Held] = []
  private(set) var started = 0

  /// Changes at every load, so an answer to a question about an earlier load is told apart.
  private(set) var epoch = 0

  /// Counts a download that starts now, and tells whether it is within the free limit.
  mutating func countStart() -> Bool {
    guard started < Self.freeLimit else { return false }

    started += 1
    return true
  }

  /// Keeps a decision. False when the bound is full, and the caller cancels the decision.
  mutating func hold(_ decision: Held) -> Bool {
    guard held.count < Self.heldLimit else { return false }

    held.append(decision)
    return true
  }

  mutating func setPhase(_ phase: Phase) {
    self.phase = phase
  }

  /// Hands over the held decisions and forgets them.
  mutating func takeHeld() -> [Held] {
    let taken = held

    held = []

    return taken
  }

  /// The page loaded again. Everything from the earlier load ends. The caller resolves the held
  /// decisions first.
  mutating func reset() {
    self = DownloadHold(epoch: epoch &+ 1)
  }

  private init(epoch: Int) {
    self.epoch = epoch
  }

  init() {}
}

/// Whether the navigation in progress is the one a click or a typed load of the user's started.
///
/// WebKit gives a response no link to the click that caused it, so the tab follows the navigation
/// instead. The flag covers that one navigation and its redirects. It never outlives them: a click
/// that starts no main-frame navigation, such as one on a `#fragment`, a `download` link, a link
/// that opens a window, or one that was cancelled, is never confirmed by a provisional start. The
/// next action decision then finds it unconfirmed and ends it, so a later script navigation does
/// not pass as the user's.
struct UserNavigation {
  enum State: Equatable {
    case none

    /// The user typed an address. The first main-frame action decision is that load's own.
    case typed

    /// A click of the user's was allowed, and WebKit has not started the navigation yet.
    case armed

    /// The navigation the user started is in flight. Redirects continue it.
    case inFlight
  }

  private(set) var state = State.none

  /// The user asked for a load. Its own action decision follows.
  mutating func typedLoad() {
    state = .typed
  }

  /// An action decision arrived. Returns whether this action is the user's.
  mutating func decideAction(
    followedByUser: Bool, isMainFrame: Bool, isRedirectLike: Bool
  ) -> Bool {
    let first = state == .typed && isMainFrame
    let continues = state == .inFlight && isMainFrame && isRedirectLike

    if followedByUser || first {
      state = .armed
    } else if !continues {
      state = .none
    }

    return followedByUser || first || continues
  }

  /// WebKit started a provisional navigation, which confirms an armed click.
  mutating func started() {
    if state == .armed { state = .inFlight }
  }

  /// A response arrived. Returns whether it answers the user's navigation. A main-frame response
  /// ends the navigation either way.
  mutating func response(isMainFrame: Bool) -> Bool {
    let byUser = state == .inFlight && isMainFrame

    if isMainFrame { state = .none }

    return byUser
  }

  /// The navigation failed, committed, or was replaced.
  mutating func end() {
    state = .none
  }
}
