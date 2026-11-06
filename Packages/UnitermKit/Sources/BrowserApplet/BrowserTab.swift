import AppKit
import AppletKit
import BrowserModel
import StatusKit
import WebKit

/// What a tab tells its applet. The applet turns each into a notice, a refresh, or both.
@MainActor
protocol BrowserTabDelegate: AnyObject {
  /// The page, its title, its loading state, or the history changed.
  func tabDidChange(_ tab: BrowserTab)

  /// Something the user should hear about, such as a refused navigation or a failed load.
  func tab(_ tab: BrowserTab, notice level: StatusLevel, text: String)

  /// Asks the user a question for the tab. Nothing in the tab waits on it except the one
  /// navigation that raised it.
  func tab(_ tab: BrowserTab, confirm request: AppletConfirmation) async -> Bool

  /// The user pressed a history button on the mouse over the tab's page.
  func tab(_ tab: BrowserTab, historyButton: BrowserWebView.HistoryButton)
}

/// Why a reload, a back, or a forward did not go ahead.
enum HistoryMove: Equatable {
  case moved

  /// There was nowhere to go.
  case unavailable

  /// A tab that never loaded has a stored address the rule refuses.
  case refused(SchemeRefusal, address: String)
}

/// One page's web view and what the applet needs to know about it.
///
/// The tab owns every load decision that is about a page: which schemes load, which results of a
/// form post are never reloaded silently, and which load failures are worth reporting. The applet
/// owns what the user sees around it.
@MainActor
final class BrowserTab: NSObject {
  let id: AppletTabID

  /// The tab's web view. It is built on first use, so a restored tab nobody has looked at holds no
  /// web view and no content process.
  lazy var webView: WKWebView = makeWebView()

  /// Whether the web view exists. It never goes back to false while the tab is open.
  private(set) var isMaterialized = false

  weak var delegate: (any BrowserTabDelegate)?

  /// What began the tab's current load. A notice from the tab takes its delivery from it, so a
  /// background tab restored at launch stays as quiet as a restore is.
  var loadOrigin = LoadOrigin.user

  /// The last committed address and title, as the description stores them.
  private(set) var record: BrowserDescription.Tab

  /// The address the user is looking at, from the web view. Nil before the first commit.
  private(set) var currentURL: URL?

  private(set) var pageTitle: String?
  private(set) var isLoading = false
  private(set) var canGoBack = false
  private(set) var canGoForward = false

  /// Whether the address bar should warn about the current page. It is recomputed whenever the
  /// address or WebKit's secure-content flag changes, so it follows a page that loads insecure
  /// content after commit and a navigation to a page with none.
  private(set) var showsSecurityWarning = false

  /// The method of the main-frame request the policy last saw. A commit that follows it takes it as
  /// the method that produced the page.
  private var lastMainFrameMethod = "GET"

  /// The history entries that a form post produced. Reloading, or going back or forward onto one,
  /// would send the form again.
  private let postResults = NSMapTable<WKBackForwardListItem, NSNumber>.weakToStrongObjects()

  /// The address of the load this tab last ended with a policy decision, after telling the user.
  private var cancelledAddress: String?

  /// The one question the gate has put to the user, with the navigation it holds.
  private var pendingResend: PendingResend?

  /// What the applet's own Reload, Back, or Forward is about to ask of the web view. The gate takes
  /// it at the next main-frame decision and clears it, so it never carries over to a later
  /// navigation. Nothing else sets it, so a page script, a swipe, and the web view's own Reload
  /// never reach the question.
  private var resendIntent: ResendIntent?

  private enum ResendIntent {
    case reload
    case history
  }

  /// The history WebKit handed back when a closed tab reopened. It applies at the first load.
  private var restoredState: Data?

  /// Whether a load began, from the stored address, a restored history, or the user.
  private(set) var hasBegunLoading = false

  private let dataStore: WKWebsiteDataStore
  private var observations: [NSKeyValueObservation] = []

  init(
    id: AppletTabID, record: BrowserDescription.Tab, dataStore: WKWebsiteDataStore,
    restoredState: Data? = nil
  ) {
    self.id = id
    self.record = record
    self.dataStore = dataStore
    self.restoredState = restoredState

    super.init()
  }

  private func makeWebView() -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = dataStore

    let view = BrowserWebView(frame: .zero, configuration: configuration)

    isMaterialized = true

    view.navigationDelegate = self
    view.uiDelegate = self
    view.allowsBackForwardNavigationGestures = true
    view.setAccessibilityIdentifier("browser-web")
    view.onHistoryButton = { [weak self] button in
      guard let self else { return }

      delegate?.tab(self, historyButton: button)
    }

    observe(view)

    return view
  }

  var hasLoadedNothing: Bool { !isMaterialized || (webView.url == nil && !isLoading) }

  /// WebKit's record of the tab's history and scroll positions, for a tab that is closing. A tab
  /// that never loaded hands back the record it was given.
  var interactionData: Data? {
    isMaterialized ? webView.interactionState as? Data : restoredState
  }

  // MARK: Loading

  /// Loads an address that already passed the scheme rule for its source. The caller checks it,
  /// since a refusal is the caller's to present.
  func load(_ url: URL) {
    hasBegunLoading = true
    restoredState = nil
    pendingResend?.resolve(.cancel)
    pendingResend = nil
    webView.load(URLRequest(url: url))
  }

  /// Records that the stored address was refused, so selecting the tab again does not try it again.
  func noteRefusedStoredLoad() {
    hasBegunLoading = true
  }

  /// Starts the tab's first load from an address that passed the scheme rule for a restored tab.
  /// A reopened tab brings WebKit's history back instead, so its back and forward steps work.
  func loadStored(_ url: URL) {
    guard let state = restoredState else {
      load(url)
      return
    }

    restoredState = nil
    hasBegunLoading = true
    webView.interactionState = state
  }

  func reload() -> HistoryMove {
    guard isMaterialized, webView.url != nil else {
      guard let address = record.url else { return .unavailable }

      guard let stored = URL(string: address) else {
        return .refused(.notAnAddress, address: address)
      }

      switch SchemePolicy.decide(stored, source: .restored) {
      case .allow:
        loadStored(stored)
        return .moved

      case .refuse(let refusal):
        return .refused(refusal, address: address)
      }
    }

    resendIntent = .reload
    webView.reload()
    return .moved
  }

  func goBack() -> HistoryMove {
    guard isMaterialized, webView.backForwardList.backItem != nil else { return .unavailable }

    resendIntent = .history
    _ = webView.goBack()
    return .moved
  }

  func goForward() -> HistoryMove {
    guard isMaterialized, webView.backForwardList.forwardItem != nil else { return .unavailable }

    resendIntent = .history
    _ = webView.goForward()
    return .moved
  }

  private func isPostResult(_ item: WKBackForwardListItem) -> Bool {
    postResults.object(forKey: item)?.boolValue ?? false
  }

  /// Stops loading and drops every reference between the web view and this tab. A question the tab
  /// was waiting on is answered no, so the navigation it held ends.
  func close() {
    pendingResend?.resolve(.cancel)
    pendingResend = nil
    restoredState = nil
    observations = []

    guard isMaterialized else { return }

    webView.stopLoading()
    webView.navigationDelegate = nil
    webView.uiDelegate = nil
    (webView as? BrowserWebView)?.onHistoryButton = nil
    webView.removeFromSuperview()
  }

  // MARK: Observation

  private func observe(_ webView: WKWebView) {
    observations = [
      webView.observe(\.title) { [weak self] _, _ in
        MainActor.assumeIsolated { self?.titleChanged() }
      },
      webView.observe(\.isLoading) { [weak self] _, _ in
        MainActor.assumeIsolated { self?.stateChanged() }
      },
      webView.observe(\.canGoBack) { [weak self] _, _ in
        MainActor.assumeIsolated { self?.stateChanged() }
      },
      webView.observe(\.canGoForward) { [weak self] _, _ in
        MainActor.assumeIsolated { self?.stateChanged() }
      },
      webView.observe(\.url) { [weak self] _, _ in
        MainActor.assumeIsolated { self?.stateChanged() }
      },
      webView.observe(\.hasOnlySecureContent) { [weak self] _, _ in
        MainActor.assumeIsolated { self?.stateChanged() }
      },
    ]
  }

  private func titleChanged() {
    let title = webView.title.flatMap { $0.isEmpty ? nil : $0 }
    pageTitle = title

    if webView.url != nil, BrowserDescription.storableURL(webView.url) != nil {
      record.title = BrowserDescription.boundedTitle(title)
    }

    delegate?.tabDidChange(self)
  }

  private func stateChanged() {
    currentURL = webView.url
    isLoading = webView.isLoading
    canGoBack = webView.canGoBack
    canGoForward = webView.canGoForward
    showsSecurityWarning = SecurityIndicator.warns(
      url: webView.url, hasOnlySecureContent: webView.hasOnlySecureContent)

    delegate?.tabDidChange(self)
  }

  private func committed() {
    if let item = webView.backForwardList.currentItem {
      postResults.setObject(NSNumber(value: lastMainFrameMethod == "POST"), forKey: item)
    }

    guard let stored = BrowserDescription.storableURL(webView.url) else { return }

    record.url = stored
    record.title = BrowserDescription.boundedTitle(webView.title)
  }

  private func report(_ error: any Error, for url: URL?) {
    let failure = error as NSError

    if failure.domain == NSURLErrorDomain, failure.code == NSURLErrorCancelled { return }

    let failing = (failure.userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.absoluteString

    // WebKit reports an interrupted load, code 102, for every load a policy decision ended. A
    // decision of this tab has already told the user, so its own address stays quiet. Any other
    // interruption is a failure the user has not heard about.
    if failure.domain == "WebKitErrorDomain", failure.code == 102, let failing,
      failing == cancelledAddress
    {
      cancelledAddress = nil
      return
    }

    let address = AddressDisplay.bounded(failing ?? url?.absoluteString ?? "the page")

    delegate?.tab(
      self, notice: .warning, text: "Could not load \(address). \(failure.localizedDescription)")
  }
}

extension BrowserTab: WKNavigationDelegate {
  func webView(
    _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
  ) {
    guard let url = navigationAction.request.url else {
      decisionHandler(.cancel)
      return
    }

    let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true

    switch SchemePolicy.decide(url, source: .page, isMainFrame: isMainFrame) {
    case .allow:
      break

    case .refuse(let refusal):
      cancel(url, notice: refusal.message(for: url.absoluteString), decisionHandler)
      return
    }

    // A reload, a swipe, a menu Reload, and a history step can each land on a form post. WebKit
    // reports the reload and the resubmit with their own types, and a history step as a step with
    // the post's method. One gate here covers every path that would send the form again. A form's
    // first submission, and a redirect it follows, are not these types.
    let intent = isMainFrame ? resendIntent : nil

    if isMainFrame { resendIntent = nil }

    if isMainFrame, repeatsPost(navigationAction) {
      resendOrRefuse(url, navigationAction, intent: intent, decisionHandler)
      return
    }

    if navigationAction.shouldPerformDownload {
      cancel(url, notice: Self.noDownloads(url), decisionHandler)
      return
    }

    if isMainFrame {
      lastMainFrameMethod = navigationAction.request.httpMethod ?? "GET"
    }

    decisionHandler(.allow)
  }

  /// A response the browser cannot show, or one the server marks as an attachment, would download.
  /// Downloads are not built yet, so the load ends with a warning. WebKit reports it as an
  /// interrupted load otherwise, with no word to the user.
  func webView(
    _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
    decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
  ) {
    guard navigationResponse.isForMainFrame, let url = navigationResponse.response.url else {
      decisionHandler(.allow)
      return
    }

    let disposition = (navigationResponse.response as? HTTPURLResponse)?
      .value(forHTTPHeaderField: "Content-Disposition")?
      .trimmingCharacters(in: .whitespaces).lowercased()
    let isAttachment = disposition?.hasPrefix("attachment") ?? false

    guard navigationResponse.canShowMIMEType, !isAttachment else {
      cancelledAddress = url.absoluteString
      delegate?.tab(self, notice: .warning, text: Self.noDownloads(url))
      decisionHandler(.cancel)
      return
    }

    decisionHandler(.allow)
  }

  /// Whether the navigation would send a form again.
  private func repeatsPost(_ action: WKNavigationAction) -> Bool {
    switch action.navigationType {
    case .formResubmitted:
      return true

    case .backForward, .reload:
      return action.request.httpMethod == "POST"

    default:
      return false
    }
  }

  /// Whether the entry the navigation lands on is one this tab saw a form post produce. WebKit
  /// has already made the target the current entry when the gate runs, so the entry's identity
  /// answers. A tab restored or reopened from history has seen none, so its post results never
  /// qualify, whatever address a seen post had.
  private func landsOnSeenPost() -> Bool {
    guard isMaterialized, let item = webView.backForwardList.currentItem else { return false }

    return isPostResult(item)
  }

  /// Whether the applet's own button, menu item, or key asked for this kind of navigation.
  private func intent(_ intent: ResendIntent?, covers action: WKNavigationAction) -> Bool {
    switch (intent, action.navigationType) {
    case (.reload, .reload), (.reload, .formResubmitted), (.history, .backForward):
      return true

    default:
      return false
    }
  }

  /// The one place a form can be sent again. The user is asked, and the navigation waits for the
  /// answer. Only a repeat the applet's own Reload, Back, or Forward started can ask, and only
  /// onto a post this tab saw a form produce. Every other repeat is refused with no question. That
  /// covers a page's script, a swipe, which cannot be told from a script, a background tab, and a
  /// restored tab. A second repeat while one question is open is cancelled, not queued.
  private func resendOrRefuse(
    _ url: URL, _ action: WKNavigationAction, intent asked: ResendIntent?,
    _ decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
  ) {
    let address = AddressDisplay.bounded(url.absoluteString)

    guard intent(asked, covers: action), landsOnSeenPost(), let delegate else {
      cancel(
        url,
        notice:
          "Did not load \(address). The page came from a form, and loading it again would send the form again.",
        decisionHandler)
      return
    }

    guard pendingResend == nil else {
      cancelledAddress = url.absoluteString
      decisionHandler(.cancel)
      return
    }

    let pending = PendingResend(decisionHandler)
    pendingResend = pending

    let request = AppletConfirmation(
      title: "Send the form again?",
      detail: "\u{201C}\(address)\u{201D} came from a form. Loading it again sends the form to "
        + "the site a second time, which can repeat what the first one did.",
      confirmTitle: "Send Again", cancelTitle: "Cancel")

    Task { @MainActor [weak self, weak delegate] in
      var allowed = false

      if let self, let delegate {
        allowed = await delegate.tab(self, confirm: request)
      }

      guard let self else {
        pending.resolve(.cancel)
        return
      }

      if pendingResend === pending { pendingResend = nil }

      if allowed, !pending.isResolved {
        pending.resolve(.allow)
      } else {
        if !pending.isResolved { cancelledAddress = url.absoluteString }

        pending.resolve(.cancel)
      }
    }
  }

  private func cancel(
    _ url: URL, notice text: String,
    _ decisionHandler: @MainActor @Sendable (WKNavigationActionPolicy) -> Void
  ) {
    cancelledAddress = url.absoluteString
    delegate?.tab(self, notice: .warning, text: text)
    decisionHandler(.cancel)
  }

  private static func noDownloads(_ url: URL) -> String {
    "Did not download \(AddressDisplay.bounded(url.absoluteString)). Downloads are not available yet."
  }

  func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
    resendIntent = nil
    committed()
    stateChanged()
  }

  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: any Error
  ) {
    resendIntent = nil
    report(error, for: nil)
  }

  func webView(
    _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error
  ) {
    resendIntent = nil
    report(error, for: webView.url)
  }
}

extension BrowserTab: WKUIDelegate {
  /// Camera and microphone are denied. The app has no usage strings, so a request must not reach
  /// the system's privacy prompt.
  func webView(
    _ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
    initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
    decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void
  ) {
    decisionHandler(.deny)
  }
}

/// A navigation the gate holds while the user answers. It answers WebKit once, whichever path gets
/// there first. WebKit must hear back for every held navigation, so the tab resolves it on close.
@MainActor
private final class PendingResend {
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
