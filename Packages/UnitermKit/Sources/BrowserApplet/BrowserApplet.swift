import AppKit
import AppletKit
import BrowserModel
import StatusKit
import Theme
import WebKit

/// Shows web pages in a pane, with tabs, back, forward, and reload buttons, and an address bar.
///
/// WebKit owns the page and its process. The applet owns the tabs, the address bar, the notices,
/// and the description. The description holds each tab's last committed address and title and the
/// selected tab, and `describe()` reads memory only. The tab bar, the toolbar, and the page follow
/// the selected tab.
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
  private var alerts = AppletAlerts()
  private var started = false
  private var closed = false
  private var lastShown: Shown?

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

  /// A pane that has loaded nothing. `dataStore` holds the pane's cookies and site data.
  public convenience init(dataStore: WKWebsiteDataStore = .default()) {
    self.init(
      dataStore: dataStore,
      tabs: [BrowserTab(id: .make(), record: BrowserDescription.Tab(), dataStore: dataStore)],
      selected: 0, closed: [])
  }

  /// Restores a pane from its description. Nothing loads until `start`, and then only the selected
  /// tab. A description this build cannot read is refused.
  public convenience init(
    restoring description: AppletDescription, dataStore: WKWebsiteDataStore = .default()
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

    let carried =
      (try? description.undoState?.decoded(as: BrowserDescription.UndoState.self))?.closedTabs
      ?? []

    self.init(
      dataStore: dataStore,
      tabs: decoded.tabs.map {
        BrowserTab(id: .make(), record: $0, dataStore: dataStore)
      },
      selected: decoded.selected, closed: carried)
  }

  private init(
    dataStore: WKWebsiteDataStore, tabs: [BrowserTab], selected: Int,
    closed: [BrowserDescription.ClosedTab]
  ) {
    self.dataStore = dataStore
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
    content.show(address: Self.address(of: tab), replacingEdit: replacingEdit)
  }

  // MARK: Lifecycle

  public func start(origin: StartOrigin) {
    guard !started, !closed else { return }

    started = true

    for tab in tabs { tab.loadOrigin = origin.loadOrigin }

    loadStored(tab)
  }

  /// Begins a tab's first load from the address it stores, after the rule for a restored tab. A
  /// refused address leaves the tab blank and keeps the stored address.
  private func loadStored(_ tab: BrowserTab) {
    guard let stored = tab.record.url else { return }

    guard let url = URL(string: stored) else {
      tab.noteRefusedStoredLoad()
      post(.warning, "Did not load the stored address. It is not a valid address.", from: tab)
      return
    }

    switch SchemePolicy.decide(url, source: .restored) {
    case .allow:
      tab.loadStored(url)

    case .refuse(let refusal):
      tab.noteRefusedStoredLoad()
      post(.warning, refusal.message(for: stored), from: tab)
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
    content.tabBar.onSelect = nil
    content.tabBar.onClose = nil
    content.tabBar.onNew = nil
  }

  public func detach() {
    alerts.detach()
  }

  public func reattach() {
    alerts.reattach(from: self, to: host)
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

    let undoState =
      closedTabs.isEmpty
      ? nil : try? JSONValue(encoding: BrowserDescription.UndoState(closedTabs: closedTabs))

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

  // MARK: Navigation

  /// Loads what the user typed, as the address bar's rule reads it. A refused address leaves the
  /// page visible, posts one warning, and marks the address as invalid.
  func submit(address: String) {
    switch AddressPolicy.resolve(address) {
    case .empty:
      return

    case .load(let url, _):
      content.markAddress(invalid: false)
      tab.loadOrigin = .user
      alerts.replaceLoad()
      tab.load(url)
      content.window?.makeFirstResponder(tab.webView)

    case .refused(let refusal):
      content.markAddress(invalid: true)
      tab.loadOrigin = .user
      post(.warning, refusal.message(for: address), from: tab)
    }
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

    let opened = BrowserTab(id: .make(), record: BrowserDescription.Tab(), dataStore: dataStore)
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

  /// A restored tab nobody has looked at loads when it is first selected.
  private func loadIfNeverLoaded() {
    guard started, !tab.hasBegunLoading else { return }

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
        interactionState: tab.interactionData),
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
      id: .make(), record: entry.tab, dataStore: dataStore, restoredState: entry.interactionState)
    reopened.delegate = self

    closedTabs.removeAll { $0.stamp == stamp }

    let position = min(max(entry.index, 0), tabs.count)
    tabs.insert(reopened, at: position)
    selectedIndex = position

    showSelectedTab(replacingEdit: true)

    if started { loadStored(reopened) }

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

  func tab(_ tab: BrowserTab, historyButton: BrowserWebView.HistoryButton) {
    guard tab === self.tab else { return }

    switch historyButton {
    case .back: goBack()
    case .forward: goForward()
    }
  }

  /// Delivers a notice with the tab's own load origin. A notice from a tab that is not selected
  /// names the tab, since the user is looking at another page.
  private func post(_ level: StatusLevel, _ text: String, from source: BrowserTab) {
    guard !closed else { return }

    let named =
      source === tab
      ? text : "In the tab \u{201C}\(Self.title(of: source).prefix(80))\u{201D}: \(text)"

    alerts.deliver(AppletNotice(level, named), origin: source.loadOrigin, from: self, to: host)
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
