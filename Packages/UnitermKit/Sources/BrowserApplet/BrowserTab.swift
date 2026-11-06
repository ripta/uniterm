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
}

/// Why a reload, a back, or a forward did not go ahead.
enum HistoryMove: Equatable {
  case moved

  /// The move would send a form again. The browser refuses until it can ask first.
  case refusedResubmit

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
  let webView: WKWebView
  weak var delegate: (any BrowserTabDelegate)?

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

  private var observations: [NSKeyValueObservation] = []

  init(id: AppletTabID, record: BrowserDescription.Tab, dataStore: WKWebsiteDataStore) {
    self.id = id
    self.record = record

    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = dataStore

    webView = WKWebView(frame: .zero, configuration: configuration)

    super.init()

    webView.navigationDelegate = self
    webView.uiDelegate = self
    webView.allowsBackForwardNavigationGestures = true
    webView.setAccessibilityIdentifier("browser-web")

    observe()
  }

  var hasLoadedNothing: Bool { webView.url == nil && !isLoading }

  // MARK: Loading

  /// Loads an address that already passed the scheme rule for its source. The caller checks it,
  /// since a refusal is the caller's to present.
  func load(_ url: URL) {
    webView.load(URLRequest(url: url))
  }

  func reload() -> HistoryMove {
    guard webView.url != nil else {
      guard let address = record.url else { return .unavailable }

      guard let stored = URL(string: address) else {
        return .refused(.notAnAddress, address: address)
      }

      switch SchemePolicy.decide(stored, source: .restored) {
      case .allow:
        load(stored)
        return .moved

      case .refuse(let refusal):
        return .refused(refusal, address: address)
      }
    }

    if let item = webView.backForwardList.currentItem, isPostResult(item) {
      return .refusedResubmit
    }

    webView.reload()
    return .moved
  }

  func goBack() -> HistoryMove {
    move(to: webView.backForwardList.backItem) { $0.goBack() }
  }

  func goForward() -> HistoryMove {
    move(to: webView.backForwardList.forwardItem) { $0.goForward() }
  }

  private func move(
    to item: WKBackForwardListItem?, _ go: (WKWebView) -> WKNavigation?
  ) -> HistoryMove {
    guard let item else { return .unavailable }

    if isPostResult(item) { return .refusedResubmit }

    _ = go(webView)
    return .moved
  }

  private func isPostResult(_ item: WKBackForwardListItem) -> Bool {
    postResults.object(forKey: item)?.boolValue ?? false
  }

  /// Stops loading and drops the web view's references to this tab.
  func close() {
    observations = []
    webView.stopLoading()
    webView.navigationDelegate = nil
    webView.uiDelegate = nil
  }

  // MARK: Observation

  private func observe() {
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
    let isRepeat: Bool

    switch navigationAction.navigationType {
    case .formResubmitted:
      isRepeat = true

    case .backForward, .reload:
      isRepeat = navigationAction.request.httpMethod == "POST"

    default:
      isRepeat = false
    }

    if isMainFrame, isRepeat {
      cancel(
        url,
        notice:
          "Did not load \(AddressDisplay.bounded(url.absoluteString)). The page came from a form, and loading it again would send the form again.",
        decisionHandler)
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
    committed()
    stateChanged()
  }

  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: any Error
  ) {
    report(error, for: nil)
  }

  func webView(
    _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error
  ) {
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
