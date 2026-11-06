import AppKit
import AppletKit
import BrowserModel
import Preferences
import StatusKit
import Theme
import WebKit

/// Shows web pages in a pane, with tabs, back, forward, and reload buttons, and an address bar.
///
/// WebKit owns the page and its process. The applet owns the tabs, the address bar, the notices,
/// and the description. The description holds each tab's last committed address and title and the
/// selected tab. `describe()` also reads WebKit's history record from each open tab for the
/// undo-only part. That read is synchronous and never reaches the network. The tab bar, the
/// toolbar, and the page follow the selected tab.
///
/// Every load passes `SchemePolicy` first. A typed address, a restored tab, and a page's own
/// navigation each have a source, and the policy is the one place that says what that source may
/// load. A refused address leaves the page where it was.
@MainActor
public final class BrowserApplet: Applet, BrowserTabDelegate {
  /// The type of the description this applet writes and restores.
  public nonisolated static let descriptionTypeID = BrowserDescription.typeID

  public let typeID = BrowserApplet.descriptionTypeID
  public weak var host: (any AppletHost)?
  public let isRunningSomething = false

  public private(set) var title = BrowserApplet.untitled
  public private(set) var segments: [AppletSegment] = []
  public private(set) var publishedTabs: AppletTabList

  private static let untitled = "Browser"

  let content = BrowserView()

  /// Every tab, in the order the bar shows them. It is never empty.
  private(set) var tabs: [BrowserTab]

  private(set) var selectedIndex: Int

  /// The tabs the user closed, newest first. They hold inert data only. A closed tab's web view is
  /// gone, and its history is WebKit's opaque record.
  private var closedTabs: [BrowserDescription.ClosedTab] = []

  private let dataStore: WKWebsiteDataStore
  private let services: BrowserServices
  private var alerts = AppletAlerts()
  private var started = false
  private var closed = false
  private var lastShown: Shown?

  /// What the undo-only part was last built from.
  private struct UndoKey: Equatable {
    struct Tab: Equatable {
      var id: AppletTabID
      var version: Int
    }

    var tabs: [Tab]
    var closed: [UInt64]
  }

  private var keptUndo: (key: UndoKey, value: JSONValue?)?

  /// What the host last heard about, so an unchanged refresh stays quiet.
  private struct Shown: Equatable {
    var title: String
    var segments: [AppletSegment]
    var records: [BrowserDescription.Tab]
    var tabIDs: [AppletTabID]
    var titles: [String]
    var selected: Int
  }

  /// The selected tab.
  var tab: BrowserTab { tabs[selectedIndex] }

  /// A pane that has loaded nothing. `dataStore` holds the pane's cookies and site data. It has no
  /// default, so a construction site that forgets it does not compile, and no pane reaches WebKit's
  /// app-wide store by accident. The host passes the same store and the same `services` to every
  /// pane it builds, new or restored.
  public convenience init(dataStore: WKWebsiteDataStore, services: BrowserServices) {
    self.init(
      dataStore: dataStore, services: services,
      tabs: [
        BrowserTab(
          id: .make(), record: BrowserDescription.Tab(), dataStore: dataStore, hsts: services.hsts,
          clock: services.clock)
      ],
      selected: 0, closed: [])
  }

  /// Restores a pane from its description. Nothing loads until `start`, and then only the selected
  /// tab, and only while the pane is attached. A description this build cannot read is refused.
  public convenience init(
    restoring description: AppletDescription, dataStore: WKWebsiteDataStore,
    services: BrowserServices
  ) throws {
    guard description.type == BrowserDescription.typeID else {
      throw AppletRestoreError.wrongType(
        expected: BrowserDescription.typeID, found: description.type)
    }

    guard description.version <= BrowserDescription.currentVersion else {
      throw AppletRestoreError.newerVersion(
        found: description.version, supported: BrowserDescription.currentVersion)
    }

    let decoded: BrowserDescription

    do {
      decoded = try description.payload.decoded(as: BrowserDescription.self)
        .validated(version: description.version)
    } catch let failure as BrowserDescription.Failure {
      switch failure {
      case .newerVersion(let found, let supported):
        throw AppletRestoreError.newerVersion(found: found, supported: supported)

      case .corrupt(let reason):
        throw AppletRestoreError.corrupt(reason)
      }
    } catch {
      throw AppletRestoreError.corrupt("browser description: \(error)")
    }

    let undo = try? description.undoState?.decoded(as: BrowserDescription.UndoState.self)

    // The records line up with the tabs only when the shapes match. Anything else is a description
    // this pane did not write, and its tabs load fresh.
    let states =
      undo?.tabStates.count == decoded.tabs.count
      ? undo?.tabStates ?? [] : [Data?](repeating: nil, count: decoded.tabs.count)

    self.init(
      dataStore: dataStore, services: services,
      tabs: zip(decoded.tabs, states).map { record, state in
        BrowserTab(
          id: .make(), record: record, dataStore: dataStore, hsts: services.hsts,
          clock: services.clock, restoredState: state)
      },
      selected: decoded.selected, closed: undo?.closedTabs ?? [])
  }

  private init(
    dataStore: WKWebsiteDataStore, services: BrowserServices, tabs: [BrowserTab], selected: Int,
    closed: [BrowserDescription.ClosedTab]
  ) {
    self.dataStore = dataStore
    self.services = services
    self.tabs = tabs
    self.selectedIndex = selected
    self.closedTabs = Array(closed.prefix(BrowserDescription.closedTabDepth))

    publishedTabs = Self.published(tabs, titles: tabs.map(Self.title(of:)), selected: selected)

    wire()
    refresh()
  }

  public var view: NSView { content }

  private func wire() {
    for tab in tabs { tab.delegate = self }

    showSelectedTab(replacingEdit: false)

    content.onBack = { [weak self] in self?.goBack() }
    content.onForward = { [weak self] in self?.goForward() }
    content.onReload = { [weak self] in self?.reload() }
    content.onSubmit = { [weak self] text in self?.submit(address: text) }
    content.onLoadOverHTTP = { [weak self] in self?.loadOverHTTP() }
    content.tabBar.onSelect = { [weak self] index in self?.selectTab(at: index) }
    content.tabBar.onClose = { [weak self] index in _ = self?.closeTab(at: index) }
    content.tabBar.onNew = { [weak self] in self?.openTab() }
  }

  /// Puts the selected tab's page, buttons, warning, and address on screen. The web view reports
  /// no change until it loads something, so the buttons take their state here. Without it a new
  /// pane shows Back and Forward enabled.
  private func showSelectedTab(replacingEdit: Bool) {
    let tab = self.tab

    content.show(page: tab.webView)
    content.show(
      canGoBack: tab.canGoBack, canGoForward: tab.canGoForward, isLoading: tab.isLoading)
    content.show(securityWarning: tab.showsSecurityWarning)
    content.show(error: tab.errorPage)
    content.show(address: Self.address(of: tab), replacingEdit: replacingEdit)
  }

  // MARK: Lifecycle

  public func start(origin: StartOrigin) {
    guard !started, !closed else { return }

    started = true

    for tab in tabs { tab.loadOrigin = origin.loadOrigin }

    loadIfNeverLoaded()
  }

  /// Begins a tab's first load from the address it stores, after the rule for a restored tab. A
  /// refused address leaves the tab blank with an explanation, and keeps the stored address.
  private func loadStored(_ tab: BrowserTab) {
    guard let stored = tab.record.url else { return }

    guard let url = URL(string: stored) else {
      tab.refuseStoredAddress(stored, .notAnAddress)
      return
    }

    switch SchemePolicy.decide(url, source: .restored) {
    case .allow:
      tab.loadStored(url)

    case .refuse(let refusal):
      tab.refuseStoredAddress(stored, refusal)
    }
  }

  public func close() {
    closed = true
    alerts.discard()

    for tab in tabs {
      tab.close()
      tab.delegate = nil
    }

    content.onBack = {}
    content.onForward = {}
    content.onReload = {}
    content.onSubmit = { _ in }
    content.onLoadOverHTTP = {}
    content.tabBar.onSelect = nil
    content.tabBar.onClose = nil
    content.tabBar.onNew = nil
  }

  public func detach() {
    alerts.detach()
  }

  /// A pane that was detached at `start`, or that selected a tab while detached, loads the selected
  /// tab now. A tab that already loaded asks nothing new.
  public func reattach() {
    alerts.reattach(from: self, to: host)

    loadIfNeverLoaded()
  }

  public func focus() {
    if tab.hasLoadedNothing {
      content.focusAddress()
    } else {
      content.window?.makeFirstResponder(tab.webView)
    }
  }

  public func apply(_ palette: ThemePalette) {
    content.apply(palette)
  }

  public func describe() -> AppletDescription {
    let description = BrowserDescription(tabs: tabs.map(\.record), selected: selectedIndex)

    let undoState = undoPart()

    // The payload always encodes. The fields are plain values, so a failure is a programming error.
    // A release build falls back to an empty payload, which restores as a blank browser.
    if let payload = try? JSONValue(encoding: description) {
      return AppletDescription(
        type: BrowserDescription.typeID, version: BrowserDescription.currentVersion,
        payload: payload, undoState: undoState)
    }

    assertionFailure("the browser description failed to encode")

    return AppletDescription(
      type: BrowserDescription.typeID, version: BrowserDescription.currentVersion,
      payload: .object([:]))
  }

  /// The undo-only part, encoded once for as long as no tab's history and no closed tab changes.
  /// The window asks for a description at every change the applet reports, and a page chooses how
  /// often its title changes. Encoding a history record costs time in step with the history.
  private func undoPart() -> JSONValue? {
    let key = UndoKey(
      tabs: tabs.map { UndoKey.Tab(id: $0.id, version: $0.historyVersion) },
      closed: closedTabs.map(\.stamp))

    if let kept = keptUndo, kept.key == key { return kept.value }

    let undo = BrowserDescription.UndoState(
      closedTabs: closedTabs, tabStates: tabs.map(\.interactionData))
    let value = undo.isEmpty ? nil : try? JSONValue(encoding: undo)

    keptUndo = (key, value)

    return value
  }

  // MARK: Navigation

  /// Loads what the user typed, as the address bar's rule reads it. Text that is not an address
  /// searches with the engine Settings names now. A refused address leaves the page visible, posts
  /// one warning, and marks the address as invalid.
  func submit(address: String) {
    switch AddressPolicy.resolve(address) {
    case .empty:
      return

    case .load(let url, let assumed):
      let kept =
        assumed == .https ? AssumedLoad(url: url, typed: address) : nil

      beginTypedLoad(url, assumed: kept)

    case .search(let query):
      guard let url = services.searchEngine().searchURL(for: query) else {
        content.markAddress(invalid: true)
        tab.loadOrigin = .user
        post(.warning, SchemeRefusal.notAnAddress.message(for: address), from: tab)
        return
      }

      beginTypedLoad(url, assumed: nil)

    case .handoff(let url):
      tab.loadOrigin = .user
      handOff(url, from: tab, typed: true)

    case .refused(let refusal):
      content.markAddress(invalid: true)
      tab.loadOrigin = .user
      post(.warning, refusal.message(for: address), from: tab)
    }
  }

  private func beginTypedLoad(_ url: URL, assumed: AssumedLoad?) {
    content.markAddress(invalid: false)
    tab.loadOrigin = .user
    alerts.replaceLoad()
    tab.load(url, assumed: assumed)
    content.window?.makeFirstResponder(tab.webView)
  }

  /// Load over HTTP, offered by the error page. It resolves what the user typed again with the
  /// override, so the same function that chose HTTPS now chooses HTTP. Nothing else reaches it.
  func loadOverHTTP() {
    guard case .offerHTTP(let host, let typed)? = tab.errorPage,
      !services.hsts.contains(host: host)
    else { return }

    guard case .load(let url, _) = AddressPolicy.resolve(typed, overridingToHTTP: true),
      url.scheme?.lowercased() == "http"
    else { return }

    beginTypedLoad(url, assumed: nil)
  }

  /// Opens another app for an address the user typed or a link the user clicked. The tab has
  /// already refused a link that was not a real click. Every guard comes before any open, `mailto:`
  /// included: only the selected tab may ask, and a tab shows one question at a time.
  ///
  /// `mailto:` then opens at once, since a draft still needs the user to send it. Any other scheme
  /// asks first, naming the app and the address, and opens only on a yes. A scheme no app handles
  /// loads nothing.
  private func handOff(_ url: URL, from source: BrowserTab, typed: Bool) {
    guard !closed else { return }

    let address = AddressDisplay.bounded(url.absoluteString)

    guard source === tab else {
      refuseHandOff(
        "Did not open \(address). Only the page you are looking at can ask to open an app.",
        from: source, typed: false)
      return
    }

    guard !source.isAskingToOpenApp else {
      refuseHandOff(
        "Did not open \(address). A question about opening an app is already waiting.",
        from: source, typed: false)
      return
    }

    if AppHandoff.opensWithoutAsking(url) {
      finishHandOff(url, from: source, typed: typed)
      return
    }

    guard let appName = services.opener.applicationName(toOpen: url), let host else {
      refuseHandOff(AppHandoff.noAppMessage(for: url), from: source, typed: typed)
      return
    }

    source.isAskingToOpenApp = true

    let question = AppHandoff.question(appName: appName, url: url)
    let request = AppletConfirmation(
      title: question.title, detail: question.detail, confirmTitle: "Open",
      cancelTitle: "Cancel")

    Task { @MainActor [weak source] in
      let allowed = await host.applet(self, confirm: request)

      source?.isAskingToOpenApp = false

      guard let source, !closed, allowed else { return }

      finishHandOff(url, from: source, typed: typed)
    }
  }

  private func finishHandOff(_ url: URL, from source: BrowserTab, typed: Bool) {
    if services.opener.open(url) {
      if typed {
        content.markAddress(invalid: false)
        content.show(address: Self.address(of: source), replacingEdit: true)
      }

      return
    }

    refuseHandOff(
      "Could not open \(AddressDisplay.bounded(url.absoluteString)).", from: source, typed: typed)
  }

  private func refuseHandOff(_ text: String, from source: BrowserTab, typed: Bool) {
    if typed { content.markAddress(invalid: true) }

    post(.warning, text, from: source)
  }

  func goBack() {
    tab.loadOrigin = .user
    report(tab.goBack())
  }

  func goForward() {
    tab.loadOrigin = .user
    report(tab.goForward())
  }

  /// A reload, back, or forward onto the result of a form post reaches the tab's gate, which asks
  /// the user before the form goes again.
  func reload() {
    tab.loadOrigin = .user
    report(tab.reload())
  }

  var canGoBack: Bool { tab.canGoBack }
  var canGoForward: Bool { tab.canGoForward }

  /// Moves the keyboard to the address bar and selects its text.
  func openLocation() {
    content.focusAddress()
  }

  private func report(_ move: HistoryMove) {
    switch move {
    case .moved, .unavailable:
      return

    case .refused(let refusal, let address):
      post(.warning, refusal.message(for: address), from: tab)
    }
  }

  // MARK: Tabs

  public var tabCount: Int { tabs.count }

  public var selectedTabIndex: Int { selectedIndex }

  /// Opens a blank tab right after the selected one, selects it, and puts the keyboard in the
  /// address bar.
  func openTab() {
    guard !closed else { return }

    let opened = BrowserTab(
      id: .make(), record: BrowserDescription.Tab(), dataStore: dataStore, hsts: services.hsts,
      clock: services.clock)
    opened.delegate = self

    let position = min(selectedIndex + 1, tabs.count)
    tabs.insert(opened, at: position)
    selectedIndex = position

    showSelectedTab(replacingEdit: true)
    refresh()
    content.focusAddress()
  }

  public func selectTab(at index: Int) {
    guard !closed, tabs.indices.contains(index), index != selectedIndex else { return }

    let hadFocus = hasFocus
    selectedIndex = index

    showSelectedTab(replacingEdit: true)
    loadIfNeverLoaded()
    refresh()

    if hadFocus || tab.hasLoadedNothing { focus() }
  }

  public func selectTab(id: AppletTabID) -> Bool {
    guard let index = tabs.firstIndex(where: { $0.id == id }) else { return false }

    selectTab(at: index)
    return true
  }

  /// Selects the tab numbered `number`, counting from 1. Number 9 selects the last tab, as the
  /// terminal's tabs do.
  func selectTab(number: Int) {
    selectTab(at: number == 9 ? tabs.count - 1 : number - 1)
  }

  func step(by step: Int) {
    guard tabs.count > 1 else { return }

    selectTab(at: (selectedIndex + step + tabs.count) % tabs.count)
  }

  /// A restored tab nobody has looked at loads when it is first selected, and only while the pane
  /// is attached. A detached pane is off screen, so it loads nothing until it comes back.
  private func loadIfNeverLoaded() {
    guard started, !closed, !alerts.isDetached, !tab.hasBegunLoading else { return }

    loadStored(tab)
  }

  public func closeCurrentTab() async -> TabCloseResult {
    closeTab(at: selectedIndex)
  }

  /// Closes a tab. The last tab never closes here, since that is a pane close.
  func closeTab(at index: Int) -> TabCloseResult {
    guard tabs.count > 1 else { return .nothingToClose }

    guard !closed, tabs.indices.contains(index) else { return .declined }

    recordClosed(tabs[index], at: index)
    removeTab(at: index)
    return .closed
  }

  /// Keeps a closed tab for reopening. The stamp is taken now, so it orders the close against
  /// every other close in the window. Only inert data stays: the address, the title, and WebKit's
  /// history record.
  private func recordClosed(_ tab: BrowserTab, at index: Int) {
    guard let host else { return }

    closedTabs.insert(
      BrowserDescription.ClosedTab(
        stamp: host.issueCloseStamp(), index: index, title: Self.title(of: tab), tab: tab.record,
        interactionState: tab.liveInteractionData),
      at: 0)

    if closedTabs.count > BrowserDescription.closedTabDepth {
      closedTabs.removeLast(closedTabs.count - BrowserDescription.closedTabDepth)
    }
  }

  private func removeTab(at index: Int) {
    let hadFocus = hasFocus
    let wasSelected = index == selectedIndex
    let removed = tabs.remove(at: index)

    removed.close()
    removed.delegate = nil

    if index < selectedIndex {
      selectedIndex -= 1
    } else {
      selectedIndex = min(selectedIndex, tabs.count - 1)
    }

    showSelectedTab(replacingEdit: wasSelected)

    if wasSelected { loadIfNeverLoaded() }

    refresh()

    if hadFocus { focus() }
  }

  public var closedTabStamps: [UInt64] {
    closedTabs.map(\.stamp)
  }

  /// Builds a tab from the closed entry, at its former index clamped to the tab count, and selects
  /// it. The tab comes back with its history, and no step through that history sends a form.
  public func reopenTab(stamp: UInt64) -> TabReopenResult {
    guard !closed, let entry = closedTabs.first(where: { $0.stamp == stamp }) else {
      return .missing
    }

    let reopened = BrowserTab(
      id: .make(), record: entry.tab, dataStore: dataStore, hsts: services.hsts,
      clock: services.clock,
      restoredState: entry.interactionState)
    reopened.delegate = self

    closedTabs.removeAll { $0.stamp == stamp }

    let position = min(max(entry.index, 0), tabs.count)
    tabs.insert(reopened, at: position)
    selectedIndex = position

    showSelectedTab(replacingEdit: true)

    loadIfNeverLoaded()

    refresh()
    return .reopened(title: entry.title)
  }

  private var hasFocus: Bool {
    guard let responder = content.window?.firstResponder as? NSView else { return false }

    return responder.isDescendant(of: content)
  }

  // MARK: Tab events

  func tabDidChange(_ changed: BrowserTab) {
    if changed === tab {
      content.show(
        canGoBack: changed.canGoBack, canGoForward: changed.canGoForward,
        isLoading: changed.isLoading)

      content.show(securityWarning: changed.showsSecurityWarning)
      content.show(error: changed.errorPage)
      content.show(address: Self.address(of: changed))
    }

    refresh()
  }

  func tab(_ tab: BrowserTab, notice level: StatusLevel, text: String) {
    post(level, text, from: tab)
  }

  /// Only the selected tab asks. The gate already refuses a repeat nobody asked for, so this is the
  /// second lock: a background tab never raises a question.
  func tab(_ tab: BrowserTab, confirm request: AppletConfirmation) async -> Bool {
    guard !closed, tab === self.tab, let host else { return false }

    return await host.applet(self, confirm: request)
  }

  func tab(_ tab: BrowserTab, explained text: String) {
    post(.warning, text, from: tab, delivery: .historyOnly)
  }

  func tab(_ tab: BrowserTab, handOff url: URL) {
    handOff(url, from: tab, typed: false)
  }

  func tab(_ tab: BrowserTab, historyButton: BrowserWebView.HistoryButton) {
    guard tab === self.tab else { return }

    switch historyButton {
    case .back: goBack()
    case .forward: goForward()
    }
  }

  /// Delivers a notice with the tab's own load origin. A notice from a tab that is not selected
  /// names the tab, since the user is looking at another page.
  private func post(
    _ level: StatusLevel, _ text: String, from source: BrowserTab,
    delivery: AppletNotice.Delivery = .message
  ) {
    guard !closed else { return }

    let named =
      source === tab
      ? text : "In the tab \u{201C}\(Self.title(of: source).prefix(80))\u{201D}: \(text)"

    alerts.deliver(
      AppletNotice(level, named, delivery: delivery), origin: source.loadOrigin, from: self,
      to: host)
  }

  /// What the address bar shows for a tab. A tab that has not begun loading shows the address it
  /// stores.
  private static func address(of tab: BrowserTab) -> String {
    let url = tab.currentURL ?? (tab.hasBegunLoading ? nil : storedURL(of: tab))

    guard let url, !SecurityIndicator.isBlank(url) else { return "" }

    return url.absoluteString
  }

  private static func storedURL(of tab: BrowserTab) -> URL? {
    tab.record.url.flatMap { URL(string: $0) }
  }

  private static func title(of tab: BrowserTab) -> String {
    tab.pageTitle ?? tab.record.title ?? tab.currentURL?.host(percentEncoded: false)
      ?? storedURL(of: tab)?.host(percentEncoded: false) ?? untitled
  }

  private static func published(
    _ tabs: [BrowserTab], titles: [String], selected: Int
  ) -> AppletTabList {
    let all = zip(tabs, titles).map { AppletTab(id: $0.id, title: $1) }

    return AppletTabList(
      first: all[0], rest: Array(all.dropFirst()), selected: tabs[selected].id)
  }

  // MARK: Display

  private func refresh() {
    guard !closed else { return }

    let titles = tabs.map(Self.title(of:))

    title = titles[selectedIndex]

    segments =
      tab.isLoading
      ? [AppletSegment(symbolName: "arrow.triangle.2.circlepath", text: "Loading")] : []

    publishedTabs = Self.published(tabs, titles: titles, selected: selectedIndex)
    content.show(tabTitles: titles, selected: selectedIndex)

    let shown = Shown(
      title: title, segments: segments, records: tabs.map(\.record), tabIDs: tabs.map(\.id),
      titles: titles, selected: selectedIndex)

    guard shown != lastShown else { return }

    let tabsChanged =
      lastShown.map {
        $0.titles != shown.titles || $0.tabIDs != shown.tabIDs || $0.selected != shown.selected
      } ?? true

    lastShown = shown

    host?.appletDidChange(self)

    if tabsChanged { host?.appletTabsDidChange(self) }
  }
}
