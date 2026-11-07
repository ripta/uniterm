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
public final class BrowserApplet: Applet, BrowserTabDelegate, BrowserDownloadsDelegate {
  /// The type of the description this applet writes and restores.
  public nonisolated static let descriptionTypeID = BrowserDescription.typeID

  public let typeID = BrowserApplet.descriptionTypeID
  public weak var host: (any AppletHost)?

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

  /// The pane's downloads. The pane holds them, not the tab.
  let downloads: BrowserDownloads

  /// The JavaScript dialogs the pane's pages raised that the user has not answered.
  let dialogs = PageDialogs()

  /// The most tabs scripts may have open at once in one pane. WebKit lets a script that holds a
  /// user gesture open as many windows as it asks for, and each is a web view and a content
  /// process. A tab the user asked for, with a real click or a menu choice, neither counts nor is
  /// refused. A policy value with no setting.
  static let popupLimit = 10

  /// Whether the user heard that the limit stopped a page, so a loop of attempts says it once.
  private var warnedAboutPopups = false

  /// Whether a question is up for the user. The window shows a second question after the first, so
  /// a queued one could outlive the tab it asked about. A question that finds another up is refused
  /// instead, the way its own kind already is.
  private var isQuestionUp = false
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
    var marked: [AppletTabID]
    var dialogs: Int
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
          clock: services.clock, hang: services.hang)
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
          clock: services.clock, restoredState: state, hang: services.hang)
      },
      selected: decoded.selected, closed: undo?.closedTabs ?? [])
  }

  private init(
    dataStore: WKWebsiteDataStore, services: BrowserServices, tabs: [BrowserTab], selected: Int,
    closed: [BrowserDescription.ClosedTab]
  ) {
    self.dataStore = dataStore
    self.services = services
    self.downloads = BrowserDownloads(
      directory: services.downloadsDirectory, files: services.downloadFiles,
      sweeper: services.downloadSweeper, clock: services.clock,
      cancelGrace: services.downloadCancelGrace)
    self.tabs = tabs
    self.selectedIndex = selected
    self.closedTabs = Array(closed.prefix(BrowserDescription.closedTabDepth))

    publishedTabs = Self.published(tabs, titles: tabs.map(Self.title(of:)), selected: selected)

    downloads.delegate = self

    wire()
    refresh()
  }

  public var view: NSView { content }

  /// True while a tab holds edited form input or a download is in flight, and nothing else.
  public var isRunningSomething: Bool {
    downloads.isRunning || tabs.contains { $0.hasUnsentInput }
  }

  /// Each tab with edited input by its title, which a page chose and is cleaned, and each download
  /// by its file name.
  public var runningLabels: [String] {
    let labels =
      tabs.filter(\.hasUnsentInput).map(Self.title(of:))
      + downloads.runningNames.map { RunningLabel.clean($0, fallback: DownloadName.fallback) }

    guard labels.count > Self.labelLimit else { return labels }

    return Array(labels.prefix(Self.labelLimit)) + ["and \(labels.count - Self.labelLimit) more"]
  }

  /// The most running things a dialog names. A page can start many downloads.
  private static let labelLimit = 10

  private func wire() {
    for tab in tabs { tab.delegate = self }

    showSelectedTab(replacingEdit: false)

    content.onBack = { [weak self] in self?.goBack() }
    content.onForward = { [weak self] in self?.goForward() }
    content.onReload = { [weak self] in self?.reload() }
    content.onSubmit = { [weak self] text in self?.submit(address: text) }
    content.onLoadOverHTTP = { [weak self] in self?.loadOverHTTP() }
    content.tabBar.onSelect = { [weak self] index in self?.selectTab(at: index) }
    content.tabBar.onClose = { [weak self] index in
      Task { @MainActor in _ = await self?.closeTab(at: index) }
    }
    content.tabBar.onNew = { [weak self] in self?.openTab() }
    content.dialogView.onAnswer = { [weak self] dialog, answer in
      self?.dialogs.settle(dialog, answer)
      self?.syncDialog(restoringFocus: true)
      self?.refresh()
    }
    content.dialogView.onStop = { [weak self] dialog in self?.stopDialogs(from: dialog) }
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
    guard let stored = tab.record.url else {
      tab.loadStored(nil)
      return
    }

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
    downloads.cancelAll()
    dialogs.dismissAll()
    content.dialogView.hide()

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
    content.dialogView.onAnswer = { _, _ in }
    content.dialogView.onStop = { _ in }
  }

  /// The pane left the screen. Media in every tab pauses and stays blocked, and a dialog that a
  /// page raised waits to be shown. Downloads keep going.
  public func detach() {
    alerts.detach()

    for tab in tabs { tab.setMediaSuspended(true) }

    syncDialog(restoringFocus: false)
  }

  /// A pane that was detached at `start`, or that selected a tab while detached, loads the selected
  /// tab now. A tab that already loaded asks nothing new.
  ///
  /// Media comes out of suspension so the user can start it again. What was paused stays paused.
  public func reattach() {
    alerts.reattach(from: self, to: host)

    for tab in tabs { tab.setMediaSuspended(false) }

    loadIfNeverLoaded()
    syncDialog(restoringFocus: false)
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
    tab.load(url, assumed: assumed, byUser: true)
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

    guard !isQuestionUp || AppHandoff.opensWithoutAsking(url) else {
      refuseHandOff(
        "Did not open \(address). Another question is already waiting.", from: source, typed: false)
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
    isQuestionUp = true

    let generation = source.generation
    let question = AppHandoff.question(appName: appName, url: url)
    let request = AppletConfirmation(
      title: question.title, detail: question.detail, confirmTitle: "Open",
      cancelTitle: "Cancel")

    Task { @MainActor [weak source] in
      let allowed = await host.applet(self, confirm: request)

      isQuestionUp = false

      // An answer about a page that stopped meanwhile belongs to a page that is gone. The stop
      // already took the tab's wait away.
      guard let source, source.generation == generation else { return }

      source.isAskingToOpenApp = false

      guard !closed, allowed else { return }

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
      clock: services.clock, hang: services.hang)
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
    syncDialog(restoringFocus: false)
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
    guard started, !closed, !alerts.isDetached, !tab.hasBegunLoading, !tab.isStopped else {
      return
    }

    loadStored(tab)
  }

  public func closeCurrentTab() async -> TabCloseResult {
    await closeTab(at: selectedIndex)
  }

  /// Closes a tab. It asks first when the tab holds edited input or a download, whether or not it
  /// is selected, and closing then cancels the download. A tab with nothing to lose closes at
  /// once. The last tab never closes here, since that is a pane close, and the window asks about
  /// what it holds.
  ///
  /// A close that waits for an answer holds the pane's one question. A second request meanwhile is
  /// declined. The tab is looked up again after the answer, since it may have closed meanwhile.
  func closeTab(at index: Int) async -> TabCloseResult {
    guard tabs.count > 1 else { return .nothingToClose }

    guard !closed, tabs.indices.contains(index), !isQuestionUp else { return .declined }

    let target = tabs[index]

    if let detail = closeDetail(for: target) {
      guard let host else { return .declined }

      isQuestionUp = true
      defer { isQuestionUp = false }

      let request = AppletConfirmation(
        title: "Close this tab?", detail: detail, confirmTitle: "Close Tab",
        cancelTitle: "Cancel")

      guard await host.applet(self, confirm: request), !closed else { return .declined }
    }

    guard let current = tabs.firstIndex(where: { $0 === target }) else { return .closed }

    guard tabs.count > 1 else { return .nothingToClose }

    recordClosed(target, at: current)
    removeTab(at: current)
    return .closed
  }

  /// What a close of `tab` would lose, in words for the question, or nil when it loses nothing.
  private func closeDetail(for tab: BrowserTab) -> String? {
    var sentences: [String] = []

    if tab.hasUnsentInput {
      let label = Self.title(of: tab)

      sentences.append(
        "\u{201C}\(label)\u{201D} has text that was not sent. Closing the tab loses it.")
    }

    let running = downloads.running(for: tab)

    for entry in running.prefix(Self.labelLimit) {
      let name = RunningLabel.clean(entry.name, fallback: DownloadName.fallback)

      sentences.append("\u{201C}\(name)\u{201D} is still downloading. Closing the tab cancels it.")
    }

    if running.count > Self.labelLimit {
      sentences.append("\(running.count - Self.labelLimit) more downloads would be cancelled too.")
    }

    return sentences.isEmpty ? nil : sentences.joined(separator: " ")
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

  /// Removes a tab. Its downloads are cancelled and its dialogs dismissed first, since WebKit
  /// must hear an answer to each dialog and a download has no tab to belong to. A selected tab
  /// that closes returns the selection to `successor` when it is still open.
  private func removeTab(at index: Int, returningTo successor: BrowserTab? = nil) {
    let hadFocus = hasFocus
    let wasSelected = index == selectedIndex
    let leaving = tabs[index]

    // The cancel tells the applet its downloads changed, and the applet redraws from the tab list
    // and the selection, so both must still agree.
    downloads.cancel(for: leaving)
    dialogs.dismissAll(for: leaving)

    let removed = tabs.remove(at: index)

    if tabs.filter(\.isScriptOpened).count < Self.popupLimit { warnedAboutPopups = false }

    removed.close()
    removed.delegate = nil

    if index < selectedIndex {
      selectedIndex -= 1
    } else {
      selectedIndex = min(selectedIndex, tabs.count - 1)
    }

    if wasSelected, let successor, let position = tabs.firstIndex(where: { $0 === successor }) {
      selectedIndex = position
    }

    showSelectedTab(replacingEdit: wasSelected)

    if wasSelected { loadIfNeverLoaded() }

    syncDialog(restoringFocus: false)
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
      restoredState: entry.interactionState, hang: services.hang)
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

    guard !isQuestionUp else {
      post(.warning, "Did not send the form again. Another question is already waiting.", from: tab)
      return false
    }

    isQuestionUp = true
    defer { isQuestionUp = false }

    return await host.applet(self, confirm: request)
  }

  func tab(_ tab: BrowserTab, explained text: String) {
    post(.warning, text, from: tab, delivery: .historyOnly)
  }

  func tab(_ tab: BrowserTab, handOff url: URL) {
    handOff(url, from: tab, typed: false)
  }

  func tabUnsentInputDidChange(_ tab: BrowserTab) {
    refresh()
  }

  func tabHoldsDialog(_ tab: BrowserTab) -> Bool {
    dialogs.first(for: tab) != nil
  }

  func tabIsViewed(_ tab: BrowserTab) -> Bool {
    !closed && started && !alerts.isDetached && tab === self.tab
  }

  /// A web view that stopped answering holds input that was not sent. Only the tab the user is
  /// looking at asks, and the question names it. Any other tab keeps its view and the user decides
  /// when they come back and reload.
  func tab(confirmReplacingUnresponsive tab: BrowserTab) async -> Bool {
    guard tabIsViewed(tab), !isQuestionUp, let host else { return false }

    let label = Self.title(of: tab)
    let request = AppletConfirmation(
      title: "Replace this page?",
      detail: "\u{201C}\(label)\u{201D} is not answering and holds text that was not sent. "
        + "Replacing it loses that text. The page may only be busy.",
      confirmTitle: "Replace Page", cancelTitle: "Keep Waiting")

    isQuestionUp = true
    defer { isQuestionUp = false }

    return await host.applet(self, confirm: request)
  }

  /// A tab's content process ended or hung. The tab already dropped its web view, took back the
  /// unsent mark, and resolved its own question about sending a form. What is left is the pane's:
  /// the page's dialogs get their one answer, a wait on opening another app ends, and the user
  /// sees the stopped message only for the selected tab of an attached pane. Any other tab goes
  /// back to the not-yet-loaded state and loads when it is next selected or attached. Nothing loads
  /// here.
  func tab(_ lost: BrowserTab, didLoseContentWithFocus hadFocus: Bool, recovering: Bool) {
    guard !closed else { return }

    dialogs.dismissAll(for: lost)
    lost.isAskingToOpenApp = false

    let showsStopped = !recovering && lost === tab && started && !alerts.isDetached

    if showsStopped { lost.showStopped() }

    if lost === tab {
      showSelectedTab(replacingEdit: false)

      if hadFocus { content.window?.makeFirstResponder(tab.webView) }
    }

    syncDialog(restoringFocus: false)
    refresh()
  }

  func tab(_ tab: BrowserTab, download: WKDownload) {
    guard !closed else {
      download.cancel { _ in }
      return
    }

    downloads.adopt(download, from: tab)
  }

  func tab(_ tab: BrowserTab, present dialog: PageDialog) {
    guard !closed else {
      dialog.answer(.dismissed)
      return
    }

    dialogs.hold(dialog)
    syncDialog(restoringFocus: false)
    refresh()
  }

  /// The user chose to stop a page's dialogs. The tab learns first, so a script that continues at
  /// once finds its next dialog dismissed. The dialog on show is answered as Cancel would answer
  /// it, and the page's other waiting dialogs are dismissed too.
  private func stopDialogs(from dialog: PageDialog) {
    dialog.tab?.stopDialogs()

    dialogs.settle(dialog, .dismissed)

    if let tab = dialog.tab { dialogs.dismissAll(for: tab) }

    syncDialog(restoringFocus: true)
    refresh()
  }

  /// Shows the selected tab's oldest waiting dialog, or hides the one on show when it is not that
  /// tab's, or the pane is detached. A pane the user is not typing in keeps the keyboard where it
  /// is, so a page cannot take the focus.
  private func syncDialog(restoringFocus: Bool) {
    let wanted = closed || alerts.isDetached ? nil : dialogs.first(for: tab)
    let view = content.dialogView

    if view.shown === wanted {
      if wanted == nil, restoringFocus, !closed { focus() }

      return
    }

    guard let wanted else {
      view.hide()

      if restoringFocus, !closed { focus() }

      return
    }

    let hadFocus = hasFocus

    view.show(wanted)

    if hadFocus { content.window?.makeFirstResponder(view.preferredResponder) }
  }

  func tab(
    _ opener: BrowserTab, openWindowWith configuration: WKWebViewConfiguration,
    for action: WKNavigationAction, byUser: Bool
  ) -> BrowserTab? {
    guard !closed, let openerIndex = tabs.firstIndex(where: { $0 === opener }) else { return nil }

    if let url = action.request.url, !url.absoluteString.isEmpty,
      case .refuse(let refusal) = SchemePolicy.decide(url, source: .page, isMainFrame: true)
    {
      post(.warning, refusal.message(for: url.absoluteString), from: opener)
      return nil
    }

    guard byUser || tabs.filter(\.isScriptOpened).count < Self.popupLimit else {
      if !warnedAboutPopups {
        warnedAboutPopups = true
        post(
          .warning,
          "A page tried to open more than \(Self.popupLimit) tabs. The browser opened the first \(Self.popupLimit).",
          from: opener)
      }

      return nil
    }

    let popup = BrowserTab(
      id: .make(), adopting: configuration, opener: opener, openedByUser: byUser,
      dataStore: dataStore, hsts: services.hsts, clock: services.clock, hang: services.hang)

    popup.delegate = self
    popup.loadOrigin = .user
    popup.setMediaSuspended(alerts.isDetached)

    let position = openerIndex + 1

    tabs.insert(popup, at: position)

    // A pop-up from the tab the user is looking at opens selected. One from a background tab opens
    // beside its opener and says so, so a page the user is not looking at cannot move the
    // selection or the keyboard.
    if opener === tab {
      let hadFocus = hasFocus

      selectedIndex = position

      showSelectedTab(replacingEdit: true)
      syncDialog(restoringFocus: false)
      refresh()

      if hadFocus { content.window?.makeFirstResponder(popup.webView) }
    } else {
      if position <= selectedIndex { selectedIndex += 1 }

      refresh()
      post(.info, "A page opened a new tab in the background.", from: opener)
    }

    return popup
  }

  /// A script closed a window it opened. The last tab and the pane never close this way. A tab
  /// that holds input or a download stays open and says why, since a page must not discard what
  /// the user would be asked about. A tab a script closes is not kept for reopening, since a
  /// sign-in pop-up's address can carry a one-time code.
  func tabDidRequestClose(_ source: BrowserTab) {
    guard !closed, source.isPopup, tabs.count > 1,
      let index = tabs.firstIndex(where: { $0 === source })
    else { return }

    guard closeDetail(for: source) == nil else {
      post(
        .warning,
        "A page tried to close this tab. It holds input that was not sent, or a download, so it stayed open.",
        from: source)
      return
    }

    removeTab(at: index, returningTo: source.opener)
  }

  // MARK: Downloads

  func downloadsDidChange(_ downloads: BrowserDownloads) {
    refresh()
  }

  func downloads(_ downloads: BrowserDownloads, finished name: String, at url: URL) {
    deliverDownload(.info, DownloadMessage.finished(name))
  }

  func downloads(_ downloads: BrowserDownloads, failed name: String, reason: String) {
    deliverDownload(.warning, DownloadMessage.failed(name, reason: reason))
  }

  /// A download's outcome reaches the user whichever tab is selected, and whichever pane has
  /// focus. A detached pane records it at once and shows it on reattach.
  private func deliverDownload(_ level: StatusLevel, _ text: String) {
    guard !closed else { return }

    alerts.deliver(
      AppletNotice(level, text), origin: .user, ofLoad: false, from: self, to: host)
  }

  /// Whether a finished download is there to reveal.
  var hasFinishedDownload: Bool { downloads.latest != nil }

  /// Shows the newest finished download in Finder. A file that was moved or deleted gets a
  /// message instead, and the command stays, so the user hears why.
  func revealLatestDownload() {
    guard !closed, let latest = downloads.latest else { return }

    guard FileManager.default.fileExists(atPath: latest.url.path(percentEncoded: false)) else {
      deliverDownload(.warning, DownloadMessage.moved(latest.name))
      return
    }

    services.reveal.reveal(latest.url)
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
      ? text
      : "In the tab \u{201C}\(Self.title(of: source))\u{201D}: \(text)"

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

  /// The tab's name for the user. A page chose its title, so the name is cleaned here, once, and
  /// the tab bar, the pane title, the notices, and the questions all read the clean one.
  private static func title(of tab: BrowserTab) -> String {
    let raw =
      tab.pageTitle ?? tab.record.title ?? tab.currentURL?.host(percentEncoded: false)
      ?? storedURL(of: tab)?.host(percentEncoded: false) ?? untitled

    return RunningLabel.clean(raw, fallback: untitled)
  }

  private static func published(
    _ tabs: [BrowserTab], titles: [String], selected: Int
  ) -> AppletTabList {
    let all = zip(tabs, titles).map { AppletTab(id: $0.id, title: $1) }

    return AppletTabList(
      first: all[0], rest: Array(all.dropFirst()), selected: tabs[selected].id)
  }

  // MARK: Display

  /// The status bar's word on downloads: one download's name and percent, or a count. The host
  /// shows the segments of the focused pane only.
  private func downloadSegment() -> AppletSegment? {
    let active = downloads.active

    guard let first = active.first else { return nil }

    guard active.count == 1 else {
      return AppletSegment(symbolName: "arrow.down.circle", text: "\(active.count) downloads")
    }

    let name = RunningLabel.clean(first.name, fallback: DownloadName.fallback)
    let shown = name.count > 28 ? String(name.prefix(27)) + "\u{2026}" : name

    guard let fraction = first.fraction else {
      return AppletSegment(symbolName: "arrow.down.circle", text: shown)
    }

    return AppletSegment(
      symbolName: "arrow.down.circle", text: "\(shown) \(Int((fraction * 100).rounded(.down)))%")
  }

  private func refresh() {
    guard !closed else { return }

    let titles = tabs.map(Self.title(of:))

    title = titles[selectedIndex]

    segments =
      (tab.isLoading
        ? [AppletSegment(symbolName: "arrow.triangle.2.circlepath", text: "Loading")] : [])
      + (downloadSegment().map { [$0] } ?? [])

    publishedTabs = Self.published(tabs, titles: titles, selected: selectedIndex)
    content.show(tabTitles: titles, selected: selectedIndex)

    let shown = Shown(
      title: title, segments: segments, records: tabs.map(\.record), tabIDs: tabs.map(\.id),
      titles: titles, selected: selectedIndex, marked: tabs.filter(\.hasUnsentInput).map(\.id),
      dialogs: dialogs.pending.count)

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
