import Foundation
import WebKit

/// What a tab knows about form posts, which the navigation gate needs to refuse a silent resend.
///
/// A repeat of a post is asked about only when the applet's own Reload, Back, or Forward started
/// it, and only onto a post this tab saw a form produce. The tab asks the user and holds WebKit's
/// decision. This type keeps the facts and the held decision. It never talks to the user.
@MainActor
final class ResendGate {
  /// What the applet's own Reload, Back, or Forward is about to ask of the web view.
  enum Intent {
    case reload
    case history
  }

  /// What the applet's own Reload, Back, or Forward is about to ask of the web view.
  ///
  /// The gate takes it at the next main-frame decision and clears it, so it never carries over to
  /// a later navigation.
  ///
  /// Nothing else sets it. A page script, a swipe, and the web view's own Reload never reach the
  /// question.
  var intent: Intent?

  /// Whether the page the tab shows came from a form post.
  private(set) var cameFromForm = false

  /// Whether the history the tab holds for its next load ends on a form post. That load restores a
  /// blank page, since the gate refuses the post, and the pane then says so.
  var restoresFormResult = false

  /// The method of the main-frame request the policy last saw. A commit that follows it takes it as
  /// the method that produced the page.
  var lastMainFrameMethod = "GET"

  /// The address of the load this tab last ended with a policy decision, after telling the user.
  var cancelledAddress: String?

  /// The one question the gate has put to the user, with the navigation it holds.
  private(set) var pending: PendingResend?

  /// The history entries that a form post produced. Reloading, or going back or forward onto one,
  /// would send the form again.
  private let postResults = NSMapTable<WKBackForwardListItem, NSNumber>.weakToStrongObjects()

  /// Whether a question about sending a form again is waiting for the user.
  var isAsking: Bool { pending != nil }

  /// The intent a main-frame decision takes. It is spent by the decision.
  func takeIntent(isMainFrame: Bool) -> Intent? {
    guard isMainFrame else { return nil }

    defer { intent = nil }

    return intent
  }

  func hold(_ pending: PendingResend) {
    self.pending = pending
  }

  /// Answers the held navigation no and forgets it, so the navigation it held ends.
  func cancelPending() {
    pending?.resolve(.cancel)
    pending = nil
  }

  /// The question ended. The held navigation is forgotten only when it is still the one asked.
  func release(_ pending: PendingResend) {
    if self.pending === pending { self.pending = nil }
  }

  /// A page committed. It came from a form when the last main-frame request was a post, and the
  /// entry it made is remembered as a post result.
  func noteCommit(item: WKBackForwardListItem?) {
    cameFromForm = lastMainFrameMethod == "POST"
    restoresFormResult = false

    if let item {
      postResults.setObject(NSNumber(value: lastMainFrameMethod == "POST"), forKey: item)
    }
  }

  func isPostResult(_ item: WKBackForwardListItem) -> Bool {
    postResults.object(forKey: item)?.boolValue ?? false
  }

  /// A new page of a tab that is about to load does not come from a form.
  func resetForLoad() {
    cameFromForm = false
    restoresFormResult = false
  }

  /// The tab lost its web view. The history it keeps now ends on a form post when the page did.
  func noteWebViewLost() {
    intent = nil
    restoresFormResult = cameFromForm
  }

  /// Whether the navigation would send a form again.
  static func repeatsPost(_ action: WKNavigationAction) -> Bool {
    switch action.navigationType {
    case .formResubmitted:
      return true

    case .backForward, .reload:
      return action.request.httpMethod == "POST"

    default:
      return false
    }
  }

  /// Whether the applet's own button, menu item, or key asked for this kind of navigation.
  static func intent(_ intent: Intent?, covers action: WKNavigationAction) -> Bool {
    switch (intent, action.navigationType) {
    case (.reload, .reload), (.reload, .formResubmitted), (.history, .backForward):
      return true

    default:
      return false
    }
  }

  /// WebKit reports an interrupted load, code 102, for every load a policy decision ended. A
  /// decision of this tab has already told the user, so its own address stays quiet. The slot is
  /// spent by the report that matches it.
  func consumeCancelled(matching failing: String?) -> Bool {
    guard let failing, failing == cancelledAddress else { return false }

    cancelledAddress = nil
    return true
  }
}

/// A navigation the gate holds while the user answers. It answers WebKit once, whichever path gets
/// there first. WebKit must hear back for every held navigation, so the tab resolves it on close.
@MainActor
final class PendingResend {
  private var handler: (@MainActor @Sendable (WKNavigationActionPolicy) -> Void)?

  init(_ handler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
    self.handler = handler
  }

  var isResolved: Bool { handler == nil }

  func resolve(_ policy: WKNavigationActionPolicy) {
    guard let handler else { return }

    self.handler = nil
    handler(policy)
  }
}
