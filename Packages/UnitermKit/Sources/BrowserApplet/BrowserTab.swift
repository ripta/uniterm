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

  /// A page asked for a new window. The applet answers with the tab it built from `configuration`,
  /// or nil to refuse. WebKit needs the web view back before this returns. `byUser` is true when
  /// the user's own click on a link, or choice from the context menu, asked for it.
  func tab(
    _ tab: BrowserTab, openWindowWith configuration: WKWebViewConfiguration,
    for action: WKNavigationAction, byUser: Bool
  ) -> BrowserTab?

  /// The page's script called `window.close()` on a window it opened.
  func tabDidRequestClose(_ tab: BrowserTab)

  /// WebKit turned a navigation into a download. The applet holds it from here.
  func tab(_ tab: BrowserTab, download: WKDownload)

  /// A page raised an alert, a confirmation, or a prompt. The applet owns the answer.
  func tab(_ tab: BrowserTab, present dialog: PageDialog)

  /// The tab's unsent-input mark changed, so what a close would lose changed.
  func tabUnsentInputDidChange(_ tab: BrowserTab)

  /// The tab's content process ended or hung, and the tab dropped its web view. The applet answers
  /// by deciding whether the user sees the stopped message, by ending what the page left waiting,
  /// and by showing the tab's new web view when the tab is the selected one. `hadFocus` is true
  /// when the keyboard was in the old web view. `recovering` is true when the tab is about to load its
  /// page again by itself, as after a hang that a user's reload or navigation ran into.
  func tab(_ tab: BrowserTab, didLoseContentWithFocus hadFocus: Bool, recovering: Bool)

  /// Whether a page dialog of the tab waits for the user. A page that waits on one is not hung.
  func tabHoldsDialog(_ tab: BrowserTab) -> Bool

  /// Whether the user is looking at the tab: it is selected in a pane that is attached.
  func tabIsViewed(_ tab: BrowserTab) -> Bool

  /// Asks whether to replace a web view that stopped answering while it holds input that was not
  /// sent. The page may only be busy. False when the user declines or cannot be asked.
  func tab(confirmReplacingUnresponsive tab: BrowserTab) async -> Bool
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
  /// web view and no content process. A web view whose content process ended or hung is replaced,
  /// so callers read this each time and never keep the value.
  var webView: WKWebView {
    if let current { return current }

    let view = makeWebView()

    current = view

    return view
  }

  private var current: WKWebView?

  /// Whether the web view exists. It goes back to false when the content process ends or hangs and
  /// the tab drops the web view.
  private(set) var isMaterialized = false

  /// Whether the user is looking at the message that the page stopped. Only the selected tab of an
  /// attached pane shows it. A stopped tab never reloads on its own: the user's Reload builds a
  /// new web view.
  private(set) var isStopped = false

  /// Counts the times the tab lost its content. An answer to a question the user was asked before
  /// that, such as one about opening another app, belongs to a page that is gone.
  private(set) var generation = 0

  private var isClosed = false

  /// Whether the page the tab shows came from a form post.
  private var cameFromForm = false

  /// Whether the history the tab holds for its next load ends on a form post. That load restores a
  /// blank page, since the gate refuses the post, and the pane then says so.
  private var restoresFormResult = false

  weak var delegate: (any BrowserTabDelegate)?

  /// The tab whose page opened this one. A pop-up tab that closes itself returns the selection to
  /// it while it exists.
  weak var opener: BrowserTab?

  /// Whether WebKit built this tab's web view for a new window. Only such a tab is closed by
  /// `window.close()`.
  let isPopup: Bool

  /// Whether a script asked for this tab, and not the user's own click or menu choice. Only these
  /// tabs count toward the pane's limit.
  let isScriptOpened: Bool

  /// Whether the tab holds edited form input. It clears on every load and when the fields return
  /// to their defaults.
  var hasUnsentInput: Bool { unsent.isMarked }

  let unsent = UnsentInputTracker()

  /// How many dialogs the page has raised since its last load, and whether the user heard that
  /// the rest are dismissed.
  private var dialogsThisLoad = 0
  private var warnedAboutDialogs = false

  /// Whether the tab's media is suspended, as a detached pane's is.
  private(set) var isMediaSuspended = false

  /// The configuration WebKit gave a pop-up, used once to build its web view.
  private var adopted: WKWebViewConfiguration?

  /// What began the tab's current load. A notice from the tab takes its delivery from it, so a
  /// background tab restored at launch stays as quiet as a restore is.
  var loadOrigin = LoadOrigin.user

  /// The last committed address and title, as the description stores them.
  private(set) var record: BrowserDescription.Tab

  /// The address the user is looking at, from the web view. Nil before the first commit.
  private(set) var currentURL: URL?

  /// The address of the page that last committed. WebKit moves `url` to a new page before it
  /// commits, so a download that starts from a link needs this one to name where it came from.
  private(set) var committedURL: URL?

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

  /// Whether a question about sending a form again is waiting for the user.
  var isAskingToResend: Bool { pendingResend != nil }

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

  /// The note that the user asked for a window: a real click on a link, or a choice from the
  /// context menu. The next request for a window takes it, once, within the same bound.
  private var windowGesture = LinkGesture()
  private let clock: @Sendable () -> Date

  /// The history WebKit handed back when a closed tab reopened. It applies at the first load.
  private var restoredState: Data?

  /// Whether a load began, from the stored address, a restored history, or the user.
  private(set) var hasBegunLoading = false

  private let dataStore: WKWebsiteDataStore
  private let hsts: HSTSStore
  private let hang: HangPolicy
  private var observations: [NSKeyValueObservation] = []

  /// The last history record read from a view that had committed a page.
  private var lastReadInteraction: Data?

  /// The address of the last load the tab began from a typed address, for a tab that stops before
  /// any page committed.
  private var lastRequested: URL?

  /// What the tab does when the bound runs out, and the cancel of the bound that is waiting.
  private var hangReplay: HangReplay?
  private var hangCancel: HangPolicy.Cancel?

  /// Counts the signs of life. A question about replacing a web view that waited for an answer
  /// drops its yes when the process spoke meanwhile.
  private var lifeSigns = 0
  private(set) var isAskingToReplace = false

  private enum HangReplay {
    case restore
    case typed(URL, AssumedLoad?)
  }

  init(
    id: AppletTabID, record: BrowserDescription.Tab, dataStore: WKWebsiteDataStore,
    hsts: HSTSStore, clock: @escaping @Sendable () -> Date = Date.init, restoredState: Data? = nil,
    hang: HangPolicy = .live
  ) {
    self.id = id
    self.record = record
    self.dataStore = dataStore
    self.hsts = hsts
    self.hang = hang
    self.clock = clock
    self.restoredState = restoredState
    self.isPopup = false
    self.isScriptOpened = false

    super.init()
  }

  /// A tab built from the configuration WebKit passed for a new window. WebKit ties the new page
  /// to its opener through that configuration, so `window.opener` works and the website data
  /// store is the opener's, which is the browser's shared one. The web view is built at once,
  /// since WebKit needs it back from the same call. The page loads on its own, so the tab counts
  /// as having begun loading.
  init(
    id: AppletTabID, adopting configuration: WKWebViewConfiguration, opener: BrowserTab,
    openedByUser: Bool, dataStore: WKWebsiteDataStore, hsts: HSTSStore,
    clock: @escaping @Sendable () -> Date, hang: HangPolicy = .live
  ) {
    self.id = id
    self.record = BrowserDescription.Tab()
    self.dataStore = dataStore
    self.hsts = hsts
    self.hang = hang
    self.clock = clock
    self.isPopup = true
    self.isScriptOpened = !openedByUser
    self.adopted = configuration
    self.hasBegunLoading = true
    self.opener = opener

    super.init()

    _ = webView
  }

  private func makeWebView() -> WKWebView {
    let fromScratch = adopted == nil
    let configuration = adopted ?? WKWebViewConfiguration()

    adopted = nil

    // A pop-up's own configuration already carries the opener's store. A pop-up rebuilt after its
    // process ended has no configuration from WebKit, so it takes the browser's store like any tab.
    if fromScratch { configuration.websiteDataStore = dataStore }

    // WKWebView on macOS lets a script open a window with no user gesture unless this is false.
    // The browser blocks it, as every other browser does, so a page cannot open tabs on its own.
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

    // Each web view gets its own controller. A controller takes one handler of a name in a world,
    // so a pop-up that shared its opener's would raise an exception, and would report into the
    // opener's tab.
    let controller = WKUserContentController()

    configuration.userContentController = controller
    unsent.install(in: controller)
    unsent.onChange = { [weak self] in
      guard let self else { return }

      delegate?.tabUnsentInputDidChange(self)
    }

    let view = BrowserWebView(frame: .zero, configuration: configuration)

    isMaterialized = true

    if isMediaSuspended { suspendMedia(view) }

    view.navigationDelegate = self
    view.uiDelegate = self
    view.allowsBackForwardNavigationGestures = true
    view.setAccessibilityIdentifier("browser-web")
    view.onMouseUp = { [weak self] in self?.noteMouseUp() }
    view.onMenuChoice = { [weak self] in self?.noteUserWindowRequest() }
    view.onHistoryButton = { [weak self] button in
      guard let self else { return }

      delegate?.tab(self, historyButton: button)
    }

    observe(view)

    return view
  }

  /// Suspends or resumes the tab's media, as a pane's detach and reattach ask. A suspended web
  /// view refuses every attempt to play until it is told to resume. Suspending alone is not enough,
  /// since WebKit lets media that was playing, or was about to, carry on when the suspension lifts.
  /// So the media is paused first, and lifting the suspension then restarts nothing. A tab with no
  /// web view yet takes the state when it gets one.
  func setMediaSuspended(_ suspended: Bool) {
    guard suspended != isMediaSuspended else { return }

    isMediaSuspended = suspended

    guard isMaterialized else { return }

    if suspended {
      suspendMedia(webView)
    } else {
      resumeMedia(webView)
    }
  }

  /// Whether the web view holds a suspension that only a resume lifts. WebKit wants the two in
  /// pairs, so a second suspend or a resume with none outstanding is never sent.
  private var holdsMediaSuspension = false

  private func suspendMedia(_ view: WKWebView) {
    view.pauseAllMediaPlayback { [weak self] in
      guard let self, isMediaSuspended, isMaterialized, !holdsMediaSuspension else { return }

      holdsMediaSuspension = true
      webView.setAllMediaPlaybackSuspended(true, completionHandler: nil)
    }
  }

  private func resumeMedia(_ view: WKWebView) {
    guard holdsMediaSuspension else { return }

    holdsMediaSuspension = false
    view.setAllMediaPlaybackSuspended(false, completionHandler: nil)
  }

  /// The user chose a new-tab item from the context menu.
  func noteUserWindowRequest() {
    windowGesture.noteMouseUp(at: clock())
  }

  /// A real left mouse-up reached the web view. A tab's next link decision may count as followed by
  /// the user, once, within the bound.
  func noteMouseUp() {
    gesture.noteMouseUp(at: clock())
  }

  var hasLoadedNothing: Bool { !isMaterialized || (webView.url == nil && !isLoading) }

  /// Whether a stop has something to bring back: a page that committed, a history record, or an
  /// address a load began for.
  private var hasPageToRestore: Bool {
    restoredState != nil || record.url != nil || lastRequested != nil
  }

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

    if let record, committedURL != nil { lastReadInteraction = record }

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
  ///
  /// `byUser` is true for an address the user typed. Such a load on a web view that already exists
  /// arms the bound for a content process that never answers.
  func load(_ url: URL, assumed: AssumedLoad? = nil, byUser: Bool = false) {
    let existed = isMaterialized

    hasBegunLoading = true
    isStopped = false
    cameFromForm = false
    restoresFormResult = false
    lastRequested = url
    restoredState = nil
    historyChanged()
    errorPage = nil
    failedLoad = nil
    self.assumed = assumed
    pendingResend?.resolve(.cancel)
    pendingResend = nil
    webView.load(URLRequest(url: url))

    if byUser, existed { armHang(.typed(url, assumed)) }
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

    if restoresFormResult {
      restoresFormResult = false

      let page = LoadErrorPage.formNotSent(address: url.absoluteString)

      errorPage = page

      delegate?.tabDidChange(self)
    }
  }

  func reload() -> HistoryMove {
    if errorPage != nil, let failed = failedLoad {
      load(failed.url, assumed: failed.assumed, byUser: true)
      return .moved
    }

    if isStopped {
      isStopped = false
      errorPage = nil
      delegate?.tabDidChange(self)
    }

    guard isMaterialized, webView.url != nil else {
      guard let address = record.url else {
        guard let requested = lastRequested else { return .unavailable }

        load(requested)
        return .moved
      }

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
    armHang(.restore)
    return .moved
  }

  func goBack() -> HistoryMove {
    guard isMaterialized, webView.backForwardList.backItem != nil else { return .unavailable }

    resendIntent = .history
    _ = webView.goBack()
    armHang(.restore)
    return .moved
  }

  func goForward() -> HistoryMove {
    guard isMaterialized, webView.backForwardList.forwardItem != nil else { return .unavailable }

    resendIntent = .history
    _ = webView.goForward()
    armHang(.restore)
    return .moved
  }

  private func isPostResult(_ item: WKBackForwardListItem) -> Bool {
    postResults.object(forKey: item)?.boolValue ?? false
  }

  /// Stops loading and drops every reference between the web view and this tab. A question the tab
  /// was waiting on is answered no, so the navigation it held ends.
  func close() {
    isClosed = true

    cancelHang()
    pendingResend?.resolve(.cancel)
    pendingResend = nil
    restoredState = nil
    errorPage = nil
    failedLoad = nil
    assumed = nil
    observations = []

    unsent.onChange = nil
    unsent.remove()

    guard isMaterialized else { return }

    webView.stopLoading()
    detach(webView)
  }

  /// Takes every reference between the web view and this tab away, and the web view off the screen.
  private func detach(_ view: WKWebView) {
    view.navigationDelegate = nil
    view.uiDelegate = nil
    (view as? BrowserWebView)?.onHistoryButton = nil
    (view as? BrowserWebView)?.onMouseUp = nil
    (view as? BrowserWebView)?.onMenuChoice = nil
    view.removeFromSuperview()
  }

  // MARK: Recovery

  /// The content process ended or hung. The tab drops its web view, so the next load builds a new
  /// one from the address and the history record, the way a reopened tab is built. It never asks
  /// the old process, which may never answer.
  ///
  /// What the page left waiting ends here. A question about sending a form again resolves as no.
  /// The unsent mark clears, since the input went with the process. A load after this never sends a
  /// form, since the new view restores history and the gate refuses a repeated post.
  private func replaceWebView() {
    cancelHang()

    let state = restoredState ?? currentInteraction()

    pendingResend?.resolve(.cancel)
    pendingResend = nil
    unsent.clear()
    unsent.remove()

    let old = current

    observations = []

    if let old { detach(old) }

    current = nil
    isMaterialized = false
    holdsMediaSuspension = false
    restoredState = state
    keptInteraction = nil
    hasBegunLoading = false
    isLoading = false
    currentURL = nil
    committedURL = nil
    canGoBack = false
    canGoForward = false
    showsSecurityWarning = false
    errorPage = nil
    failedLoad = nil
    assumed = nil
    resendIntent = nil
    restoresFormResult = cameFromForm
    dialogsThisLoad = 0
    warnedAboutDialogs = false
    gesture = LinkGesture()
    windowGesture = LinkGesture()
    generation &+= 1

    historyChanged()
  }

  /// The history record of the page the tab has now. A view that has not committed a page reports a
  /// small record of its own, measured at 186 bytes against 719 for two pages, and a stop must
  /// never replace the history with it. Such a view stands in with the last record read from a view
  /// that did commit one.
  private func currentInteraction() -> Data? {
    guard isMaterialized else { return nil }

    guard committedURL != nil else { return lastReadInteraction }

    return readInteraction() ?? lastReadInteraction
  }

  /// Shows the message that the page stopped, when there is a page to bring back. A tab with
  /// nothing to restore stays blank, since the user lost no page.
  func showStopped() {
    guard hasPageToRestore else { return }

    isStopped = true

    let page = LoadErrorPage.contentStopped(
      address: record.url ?? lastRequested?.absoluteString ?? "", fromForm: restoresFormResult)

    errorPage = page

    delegate?.tab(self, explained: page.historyText)
    delegate?.tabDidChange(self)
  }

  /// A load the user asked for starts a bound. A sign of life from the content process ends it.
  /// When it runs out, the web view is replaced, and a typed address then loads in the new one.
  private func armHang(_ replay: HangReplay) {
    guard isMaterialized, !isClosed else { return }

    cancelHang()

    hangReplay = replay
    hangCancel = hang.schedule(hang.bound) { [weak self] in self?.hangExpired() }
  }

  private func cancelHang() {
    hangCancel?()
    hangCancel = nil
    hangReplay = nil
  }

  /// Any callback from the web view's navigation delegate or UI delegate comes from a live process,
  /// so it ends the wait. A slow server sends the process's callbacks long before its own response.
  /// A page that raises a dialog, such as the question a `beforeunload` handler asks, is waiting
  /// for the user and not hung.
  private func sawLife() {
    lifeSigns &+= 1

    guard hangCancel != nil else { return }

    cancelHang()
  }

  /// The bound ran out. A page that waits on a dialog is not hung. A page that holds input that was
  /// not sent may only be busy, so the user decides whether to replace it. Anything else is
  /// replaced.
  private func hangExpired() {
    guard hangCancel != nil, !isClosed else { return }

    let replay = hangReplay

    hangCancel = nil
    hangReplay = nil

    guard delegate?.tabHoldsDialog(self) != true else { return }

    guard hasUnsentInput else {
      replaceHung(replay)
      return
    }

    guard !isAskingToReplace, delegate != nil, let view = current else { return }

    isAskingToReplace = true

    let signs = lifeSigns

    Task { @MainActor [weak self, weak delegate, weak view] in
      var allowed = false

      if let self, let delegate {
        allowed = await delegate.tab(confirmReplacingUnresponsive: self)
      }

      guard let self else { return }

      isAskingToReplace = false

      guard allowed, !isClosed, let view, view === current, signs == lifeSigns else { return }

      replaceHung(replay)
    }
  }

  /// A tab the user is looking at loads again at once, as the user asked. Any other tab drops its
  /// hung view and waits to be selected or attached, since a reload there would wake a tab nobody
  /// is looking at.
  private func replaceHung(_ replay: HangReplay?) {
    guard delegate?.tabIsViewed(self) == true else {
      lose(recovering: false)
      return
    }

    lose(recovering: true)

    switch replay {
    case .typed(let url, let assumed):
      let state = restoredState

      restoredState = nil

      if let state { webView.interactionState = state }

      load(url, assumed: assumed)

    case .restore, nil:
      _ = reload()
    }
  }

  /// Replaces the web view, then tells the applet. `hadFocus` is read before the old view leaves.
  private func lose(recovering: Bool) {
    let hadFocus = current.map { Self.holdsFocus($0) } ?? false

    replaceWebView()
    delegate?.tab(self, didLoseContentWithFocus: hadFocus, recovering: recovering)
  }

  private static func holdsFocus(_ view: NSView) -> Bool {
    guard let responder = view.window?.firstResponder as? NSView else { return false }

    return responder.isDescendant(of: view)
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
    isStopped = false
    historyChanged()
    errorPage = nil
    failedLoad = nil
    assumed = nil
    dialogsThisLoad = 0
    warnedAboutDialogs = false
    committedURL = webView.url
    cameFromForm = lastMainFrameMethod == "POST"
    restoresFormResult = false
    unsent.clear()

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
    sawLife()

    guard let url = navigationAction.request.url else {
      decisionHandler(.cancel)
      return
    }

    let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true

    // WebKit reports a script's click as a followed link, so only a real mouse-up seen in the view
    // makes a link the user's. Every link decision takes the note, whatever it loads, so a click
    // on one link cannot be spent on another. A link in a subframe is never the user's, since the
    // page chose that frame.
    let followedByUser =
      navigationAction.navigationType == .linkActivated && gesture.consume(at: clock())
      && navigationAction.sourceFrame.isMainFrame

    if followedByUser { windowGesture.noteMouseUp(at: clock()) }

    if navigationAction.shouldPerformDownload {
      switch SchemePolicy.decideDownload(url) {
      case .allow:
        // WebKit reports the navigation a download replaced as an interrupted load. The download
        // has its own outcome, so the load stays quiet.
        cancelledAddress = url.absoluteString
        decisionHandler(.download)

      case .refuse(let refusal):
        cancel(url, notice: refusal.message(for: url.absoluteString), decisionHandler)
      }

      return
    }

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

    if isMainFrame {
      lastMainFrameMethod = navigationAction.request.httpMethod ?? "GET"
    }

    decisionHandler(.allow)
  }

  /// A response the browser cannot show, or one the server marks as an attachment, becomes a
  /// download. That holds for a frame too, since a subframe's attachment has nowhere to show.
  func webView(
    _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
    decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
  ) {
    sawLife()

    guard let url = navigationResponse.response.url else {
      decisionHandler(.allow)
      return
    }

    if navigationResponse.isForMainFrame {
      hsts.noteResponse(
        from: url,
        header: (navigationResponse.response as? HTTPURLResponse)?
          .value(forHTTPHeaderField: "Strict-Transport-Security"))
    }

    let disposition = (navigationResponse.response as? HTTPURLResponse)?
      .value(forHTTPHeaderField: "Content-Disposition")?
      .trimmingCharacters(in: .whitespaces).lowercased()
    let isAttachment = disposition?.hasPrefix("attachment") ?? false

    guard navigationResponse.canShowMIMEType, !isAttachment else {
      switch SchemePolicy.decideDownload(url) {
      case .allow:
        cancelledAddress = url.absoluteString
        decisionHandler(.download)

      case .refuse(let refusal):
        cancelledAddress = url.absoluteString
        delegate?.tab(self, notice: .warning, text: refusal.message(for: url.absoluteString))
        decisionHandler(.cancel)
      }

      return
    }

    decisionHandler(.allow)
  }

  func webView(
    _ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload
  ) {
    adopt(download)
  }

  func webView(
    _ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload
  ) {
    adopt(download)
  }

  /// A download no pane holds would run with nobody to name it, so a tab with no delegate ends it.
  private func adopt(_ download: WKDownload) {
    guard let delegate else {
      download.cancel { _ in }
      return
    }

    delegate.tab(self, download: download)
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

  /// A new load began, so an earlier error page no longer describes the pane. A failure of this
  /// load builds its own page when it earns one. Without this, a failed Back or a failed page
  /// navigation that builds none would leave the old offer over the pane.
  func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
    sawLife()

    guard let page = errorPage else { return }

    if case .formNotSent = page { return }

    errorPage = nil
    failedLoad = nil
    delegate?.tabDidChange(self)
  }

  func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
    sawLife()

    resendIntent = nil
    committed()
    stateChanged()
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    sawLife()
    historyChanged()
  }

  /// A page's content process ended, by a crash or because the system reclaimed its memory. The tab
  /// handles its own web view and nothing else's, since a pop-up that shares its opener's process
  /// gets its own call.
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    guard webView === current, !isClosed else { return }

    lose(recovering: false)
  }

  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: any Error
  ) {
    sawLife()

    resendIntent = nil
    report(error, for: nil, isProvisional: true)
  }

  func webView(
    _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error
  ) {
    sawLife()

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
    sawLife()

    decisionHandler(.deny)
  }

  /// A page's own window, or a link that opens one, becomes a tab built from WebKit's
  /// configuration. The browser turns off `javaScriptCanOpenWindowsAutomatically`, so a script with
  /// no user gesture never reaches this method. The applet may still refuse, as for a scheme the
  /// browser does not load, or when scripts have opened too many tabs. A window the user asked
  /// for, with a real click or a menu choice, passes `byUser` and is never refused for the limit.
  func webView(
    _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    sawLife()

    let byUser = windowGesture.consume(at: clock())

    return delegate?.tab(
      self, openWindowWith: configuration, for: navigationAction, byUser: byUser)?.webView
  }

  func webViewDidClose(_ webView: WKWebView) {
    sawLife()

    delegate?.tabDidRequestClose(self)
  }

  func webView(
    _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
    initiatedByFrame frame: WKFrameInfo,
    completionHandler: @escaping @MainActor @Sendable () -> Void
  ) {
    present(.alert, message, frame) { _ in completionHandler() }
  }

  func webView(
    _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
    initiatedByFrame frame: WKFrameInfo,
    completionHandler: @escaping @MainActor @Sendable (Bool) -> Void
  ) {
    present(.confirm, message, frame) { completionHandler($0 == .accepted) }
  }

  func webView(
    _ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
    defaultText: String?, initiatedByFrame frame: WKFrameInfo,
    completionHandler: @escaping @MainActor @Sendable (String?) -> Void
  ) {
    present(.prompt(defaultText: defaultText ?? ""), prompt, frame) { answer in
      if case .text(let text) = answer {
        completionHandler(text)
      } else {
        completionHandler(nil)
      }
    }
  }

  /// Hands a dialog to the applet, which owns its answer. A page that keeps raising dialogs gets
  /// the rest dismissed, and the user hears so once. A tab with no applet dismisses at once, since
  /// WebKit must hear back from every dialog exactly once.
  private func present(
    _ kind: PageDialog.Kind, _ message: String, _ frame: WKFrameInfo,
    completion: @escaping @MainActor (PageDialog.Answer) -> Void
  ) {
    sawLife()

    let dialog = PageDialog(
      kind: kind, message: message,
      source: frame.request.url?.host(percentEncoded: false) ?? "", tab: self,
      completion: completion)

    guard let delegate else {
      dialog.answer(.dismissed)
      return
    }

    guard dialogsThisLoad < PageDialogs.perLoadLimit else {
      dialog.answer(.dismissed)

      if !warnedAboutDialogs {
        warnedAboutDialogs = true
        delegate.tab(
          self, notice: .warning,
          text: "A page kept raising dialogs. The browser dismissed the rest.")
      }

      return
    }

    dialogsThisLoad += 1
    delegate.tab(self, present: dialog)
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
