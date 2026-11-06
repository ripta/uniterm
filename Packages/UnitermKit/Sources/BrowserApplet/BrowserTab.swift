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

  /// The tab put an explanation in its pane. The history records it, and the status bar stays
  /// quiet, since the pane already says it.
  func tab(_ tab: BrowserTab, explained text: String)

  /// The user followed a link to an address that names another app.
  func tab(_ tab: BrowserTab, handOff url: URL)
}

/// An address whose scheme the browser chose, kept with the text that produced it. A failure to
/// connect to it can offer plain HTTP, and Load over HTTP resolves `typed` again.
struct AssumedLoad: Equatable {
  var url: URL
  var typed: String
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

  /// What the tab shows in place of a page it could not load, until the next load or commit.
  private(set) var errorPage: LoadErrorPage?

  /// The load the tab began with an assumed HTTPS scheme, until it commits or another load begins.
  private var assumed: AssumedLoad?

  /// The address and scheme choice of the load that failed into `errorPage`, so Reload can try it
  /// again.
  private var failedLoad: (url: URL, assumed: AssumedLoad?)?

  /// Whether a question about opening another app is waiting. A tab holds at most one.
  var isAskingToOpenApp = false

  /// The note of a real mouse-up in this tab's web view, taken by the next link decision.
  private var gesture = LinkGesture()
  private let clock: @Sendable () -> Date

  /// The history WebKit handed back when a closed tab reopened. It applies at the first load.
  private var restoredState: Data?

  /// Whether a load began, from the stored address, a restored history, or the user.
  private(set) var hasBegunLoading = false

  private let dataStore: WKWebsiteDataStore
  private let hsts: HSTSStore
  private var observations: [NSKeyValueObservation] = []

  init(
    id: AppletTabID, record: BrowserDescription.Tab, dataStore: WKWebsiteDataStore,
    hsts: HSTSStore, clock: @escaping @Sendable () -> Date = Date.init, restoredState: Data? = nil
  ) {
    self.id = id
    self.record = record
    self.dataStore = dataStore
    self.hsts = hsts
    self.clock = clock
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
    view.onMouseUp = { [weak self] in self?.noteMouseUp() }
    view.onHistoryButton = { [weak self] button in
      guard let self else { return }

      delegate?.tab(self, historyButton: button)
    }

    observe(view)

    return view
  }

  /// A real left mouse-up reached the web view. A tab's next link decision may count as followed by
  /// the user, once, within the bound.
  func noteMouseUp() {
    gesture.noteMouseUp(at: clock())
  }

  var hasLoadedNothing: Bool { !isMaterialized || (webView.url == nil && !isLoading) }

  /// WebKit's record of the tab's history and scroll positions, for a tab that is closing or a pane
  /// that is describing itself. A record the tab was given and has not applied yet comes back as it
  /// was. A web view that holds no page reports an empty record, which would replace it, so a tab
  /// with no page has none.
  ///
  /// The read is kept until something changes the history, since a read costs time in step with the
  /// history and a page chooses how often the window asks. A scroll position can be as old as the
  /// last history change. `liveInteractionData` reads past the kept value.
  var interactionData: Data? {
    if let restoredState { return restoredState }

    if let kept = keptInteraction { return kept }

    return readInteraction()
  }

  /// The record read now, for a tab that is closing, where a stale scroll position would be lost.
  var liveInteractionData: Data? {
    if let restoredState { return restoredState }

    return readInteraction()
  }

  /// Counts the changes that make the kept record stale. The applet keys its own kept description
  /// on it, so a change here reaches the applet without a second signal.
  private(set) var historyVersion = 0

  /// The last record read, or nil when nothing is kept. The inner nil is a tab with no page.
  private var keptInteraction: Data??

  private func readInteraction() -> Data? {
    var record: Data?

    if isMaterialized, webView.url != nil { record = webView.interactionState as? Data }

    keptInteraction = .some(record)

    return record
  }

  /// The history changed: a commit, a finish, a step, a same-document navigation, or a load. A
  /// title or a loading toggle is not one.
  private func historyChanged() {
    keptInteraction = nil
    historyVersion &+= 1
  }

  // MARK: Loading

  /// Loads an address that already passed the scheme rule for its source. The caller checks it,
  /// since a refusal is the caller's to present. `assumed` is set when the policy chose HTTPS for
  /// a scheme-less address, which is the one load that can offer plain HTTP when it fails.
  func load(_ url: URL, assumed: AssumedLoad? = nil) {
    hasBegunLoading = true
    restoredState = nil
    historyChanged()
    errorPage = nil
    failedLoad = nil
    self.assumed = assumed
    pendingResend?.resolve(.cancel)
    pendingResend = nil
    webView.load(URLRequest(url: url))
  }

  /// Records that the stored address was refused, so selecting the tab again does not try it again.
  /// The pane explains the refusal in place of a page, and the history records it once. The stored
  /// address stays in the description. The refusal never commits a page, so the rule that limits
  /// what a commit stores does not touch it. The user's own load clears the explanation.
  func refuseStoredAddress(_ address: String, _ refusal: SchemeRefusal) {
    hasBegunLoading = true

    let page = LoadErrorPage.refusedStoredAddress(address: address, refusal: refusal)

    errorPage = page
    failedLoad = nil

    delegate?.tab(self, explained: page.historyText)
    delegate?.tabDidChange(self)
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
    historyChanged()
    webView.interactionState = state
  }

  func reload() -> HistoryMove {
    if errorPage != nil, let failed = failedLoad {
      load(failed.url, assumed: failed.assumed)
      return .moved
    }

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
    errorPage = nil
    failedLoad = nil
    assumed = nil
    observations = []

    guard isMaterialized else { return }

    webView.stopLoading()
    webView.navigationDelegate = nil
    webView.uiDelegate = nil
    (webView as? BrowserWebView)?.onHistoryButton = nil
    (webView as? BrowserWebView)?.onMouseUp = nil
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
        MainActor.assumeIsolated {
          self?.historyChanged()
          self?.stateChanged()
        }
      },
      webView.observe(\.canGoForward) { [weak self] _, _ in
        MainActor.assumeIsolated {
          self?.historyChanged()
          self?.stateChanged()
        }
      },
      webView.observe(\.url) { [weak self] _, _ in
        MainActor.assumeIsolated {
          self?.historyChanged()
          self?.stateChanged()
        }
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
    historyChanged()
    errorPage = nil
    failedLoad = nil
    assumed = nil

    if let item = webView.backForwardList.currentItem {
      postResults.setObject(NSNumber(value: lastMainFrameMethod == "POST"), forKey: item)
    }

    guard let stored = BrowserDescription.storableURL(webView.url) else { return }

    record.url = stored
    record.title = BrowserDescription.boundedTitle(webView.title)
  }

  /// `isProvisional` is true for a load that failed before the page committed. Only those can put
  /// an error page in the pane. A failure after commit leaves the page that did load.
  private func report(_ error: any Error, for url: URL?, isProvisional: Bool = false) {
    let failure = error as NSError

    if failure.domain == NSURLErrorDomain, failure.code == NSURLErrorCancelled { return }

    let failing = (failure.userInfo[NSURLErrorFailingURLErrorKey] as? URL)

    // WebKit reports an interrupted load, code 102, for every load a policy decision ended. A
    // decision of this tab has already told the user, so its own address stays quiet. Any other
    // interruption is a failure the user has not heard about.
    if failure.domain == "WebKitErrorDomain", failure.code == 102,
      let failing = failing?.absoluteString, failing == cancelledAddress
    {
      cancelledAddress = nil
      return
    }

    if isProvisional, let failing, let page = loadErrorPage(for: failure, failing: failing) {
      errorPage = page
      failedLoad = (failing, assumed)

      delegate?.tab(self, explained: page.historyText)
      delegate?.tabDidChange(self)
      return
    }

    let address = AddressDisplay.bounded(
      failing?.absoluteString ?? url?.absoluteString ?? "the page")

    delegate?.tab(
      self, notice: .warning, text: "Could not load \(address). \(failure.localizedDescription)")
  }

  /// The page for a failed HTTPS load. A certificate failure always gets one, and never an action.
  /// A connection failure gets the offer only for the address whose HTTPS the browser assumed,
  /// and never for a host under HSTS.
  private func loadErrorPage(for error: NSError, failing: URL) -> LoadErrorPage? {
    guard failing.scheme?.lowercased() == "https",
      let host = failing.host(percentEncoded: false)
    else { return nil }

    switch LoadFailure(error).kind {
    case .certificate:
      return .certificate(host: host, reason: error.localizedDescription)

    case .unreachable:
      guard let assumed, isSameServer(failing, assumed.url), !hsts.contains(host: host) else {
        return nil
      }

      return .offerHTTP(host: host, typed: assumed.typed)

    case .other:
      return nil
    }
  }

  /// Whether two HTTPS addresses name the same host and port. A redirect to another host is not
  /// the address the user typed, so it never earns the offer.
  private func isSameServer(_ a: URL, _ b: URL) -> Bool {
    a.host(percentEncoded: false)?.lowercased() == b.host(percentEncoded: false)?.lowercased()
      && (a.port ?? 443) == (b.port ?? 443)
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

    // WebKit reports a script's click as a followed link, so only a real mouse-up seen in the view
    // makes a link the user's. Every link decision takes the note, whatever it loads, so a click
    // on one link cannot be spent on another.
    let followedByUser =
      navigationAction.navigationType == .linkActivated && gesture.consume(at: clock())

    switch SchemePolicy.decide(url, source: .page, isMainFrame: isMainFrame) {
    case .allow:
      break

    case .refuse(let refusal):
      if navigationAction.navigationType == .linkActivated,
        case .unsupported(let scheme) = refusal, AppHandoff.mayHandOff(scheme: scheme)
      {
        cancelledAddress = url.absoluteString
        decisionHandler(.cancel)

        if followedByUser {
          delegate?.tab(self, handOff: url)
        } else {
          delegate?.tab(self, notice: .warning, text: Self.unattendedHandOff(url))
        }

        return
      }

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

    hsts.noteResponse(
      from: url,
      header: (navigationResponse.response as? HTTPURLResponse)?
        .value(forHTTPHeaderField: "Strict-Transport-Security"))

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

  private static func unattendedHandOff(_ url: URL) -> String {
    "Did not open \(AddressDisplay.bounded(url.absoluteString)). A page can open another app only "
      + "from a click on its link, and this was not one."
  }

  private static func noDownloads(_ url: URL) -> String {
    "Did not download \(AddressDisplay.bounded(url.absoluteString)). Downloads are not available yet."
  }

  /// A new load began, so an earlier error page no longer describes the pane. A failure of this
  /// load builds its own page when it earns one. Without this, a failed Back or a failed page
  /// navigation that builds none would leave the old offer over the pane.
  func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
    guard errorPage != nil else { return }

    errorPage = nil
    failedLoad = nil
    delegate?.tabDidChange(self)
  }

  func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
    resendIntent = nil
    committed()
    stateChanged()
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    historyChanged()
  }

  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: any Error
  ) {
    resendIntent = nil
    report(error, for: nil, isProvisional: true)
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
