import Foundation
import WebKit

/// What the hang bound needs from the tab it watches.
@MainActor
protocol HangRecoveryOwner: AnyObject {
  var isClosed: Bool { get }

  /// The web view the bound watches, or nil when the tab holds none.
  var watchedView: WKWebView? { get }

  var holdsDialog: Bool { get }
  var hasUnsentInput: Bool { get }
  var canAsk: Bool { get }

  /// Asks whether to replace a view that holds input that was not sent.
  func askToReplace() async -> Bool

  /// Drops the hung view and loads the page again, as `replay` says.
  func replaceHung(_ replay: HangRecovery.Replay?)
}

/// The bound on a user's reload or navigation that gets no answer from the content process.
///
/// A load the user asked for starts a bound. A sign of life from the content process ends it. When
/// it runs out, the owner replaces its web view, and a typed address then loads in the new one. A
/// page that waits on a dialog is not hung. A page that holds input that was not sent may only be
/// busy, so the user decides.
@MainActor
final class HangRecovery {
  /// What the tab does when the bound runs out.
  enum Replay {
    case restore
    case typed(URL, AssumedLoad?)
  }

  weak var owner: (any HangRecoveryOwner)?

  private let policy: HangPolicy
  private var replay: Replay?
  private var cancelBound: HangPolicy.Cancel?

  /// Counts the signs of life. A question about replacing a web view that waited for an answer
  /// drops its yes when the process spoke meanwhile.
  private var lifeSigns = 0

  private(set) var isAskingToReplace = false

  init(policy: HangPolicy) {
    self.policy = policy
  }

  /// Starts the bound for a load the user asked for on a web view that exists.
  func arm(_ replay: Replay) {
    guard let owner, owner.watchedView != nil, !owner.isClosed else { return }

    cancel()

    self.replay = replay
    cancelBound = policy.schedule(policy.bound) { [weak self] in self?.expired() }
  }

  func cancel() {
    cancelBound?()
    cancelBound = nil
    replay = nil
  }

  /// Any callback from the web view's navigation delegate or UI delegate comes from a live process,
  /// so it ends the wait. A slow server sends the process's callbacks long before its own response.
  /// A page that raises a dialog, such as the question a `beforeunload` handler asks, is waiting
  /// for the user and not hung.
  func sawLife() {
    lifeSigns &+= 1

    guard cancelBound != nil else { return }

    cancel()
  }

  /// The bound ran out. A page that waits on a dialog is not hung. A page that holds input that was
  /// not sent may only be busy, so the user decides whether to replace it. Anything else is
  /// replaced.
  private func expired() {
    guard let owner, cancelBound != nil, !owner.isClosed else { return }

    let replay = replay

    cancelBound = nil
    self.replay = nil

    guard !owner.holdsDialog else { return }

    guard owner.hasUnsentInput else {
      owner.replaceHung(replay)
      return
    }

    guard !isAskingToReplace, owner.canAsk, let view = owner.watchedView else { return }

    isAskingToReplace = true

    let signs = lifeSigns

    Task { @MainActor [weak self, weak owner, weak view] in
      var allowed = false

      if let owner {
        allowed = await owner.askToReplace()
      }

      guard let self else { return }

      isAskingToReplace = false

      guard allowed, let owner, !owner.isClosed, let view, view === owner.watchedView,
        signs == lifeSigns
      else { return }

      owner.replaceHung(replay)
    }
  }
}
