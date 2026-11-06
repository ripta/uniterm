import AppKit
import AppletKit
import BrowserModel
import StatusKit
import Theme
import WebKit

/// Shows web pages in a pane, with back, forward, and reload buttons and an address bar.
///
/// WebKit owns the page and its process. The applet owns the address bar, the notices, and the
/// description. The description holds each tab's last committed address and title and the selected
/// tab, and `describe()` reads memory only.
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
  let tab: BrowserTab

  private var alerts = AppletAlerts()
  private var loadOrigin = LoadOrigin.user
  private var started = false
  private var closed = false
  private var lastShown: Shown?

  /// What the host last heard about, so an unchanged refresh stays quiet.
  private struct Shown: Equatable {
    var title: String
    var segments: [AppletSegment]
    var record: BrowserDescription.Tab
  }

  /// A pane that has loaded nothing. `dataStore` holds the pane's cookies and site data.
  public init(dataStore: WKWebsiteDataStore = .default()) {
    let id = AppletTabID.make()

    tab = BrowserTab(id: id, record: BrowserDescription.Tab(), dataStore: dataStore)
    publishedTabs = AppletTabList(first: AppletTab(id: id, title: Self.untitled))

    wire()
    refresh()
  }

  /// Restores a pane from its description. Nothing loads until `start`. A description this build
  /// cannot read is refused.
  public init(
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

    let id = AppletTabID.make()
    let selected = decoded.tabs[decoded.selected]

    tab = BrowserTab(id: id, record: selected, dataStore: dataStore)
    publishedTabs = AppletTabList(
      first: AppletTab(id: id, title: selected.title ?? Self.untitled))

    wire()
    refresh()
  }

  public var view: NSView { content }

  private func wire() {
    tab.delegate = self

    content.show(page: tab.webView)

    // The web view reports no change until it loads something, so the buttons take their first
    // state here. Without it a new pane shows Back and Forward enabled.
    content.show(canGoBack: tab.canGoBack, canGoForward: tab.canGoForward, isLoading: tab.isLoading)
    content.onBack = { [weak self] in self?.goBack() }
    content.onForward = { [weak self] in self?.goForward() }
    content.onReload = { [weak self] in self?.reload() }
    content.onSubmit = { [weak self] text in self?.submit(address: text) }
  }

  // MARK: Lifecycle

  public func start(origin: StartOrigin) {
    guard !started, !closed else { return }

    started = true
    loadOrigin = origin.loadOrigin

    guard let stored = tab.record.url else { return }

    guard let url = URL(string: stored) else {
      post(.warning, "Did not load the stored address. It is not a valid address.")
      return
    }

    switch SchemePolicy.decide(url, source: .restored) {
    case .allow:
      tab.load(url)

    case .refuse(let refusal):
      post(.warning, refusal.message(for: stored))
    }
  }

  public func close() {
    closed = true
    alerts.discard()
    tab.close()
    tab.delegate = nil
    content.onBack = {}
    content.onForward = {}
    content.onReload = {}
    content.onSubmit = { _ in }
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
    let description = BrowserDescription(tabs: [tab.record], selected: 0)

    // The payload always encodes. The fields are plain values, so a failure is a programming error.
    // A release build falls back to an empty payload, which restores as a blank browser.
    if let payload = try? JSONValue(encoding: description) {
      return AppletDescription(
        type: BrowserDescription.typeID, version: BrowserDescription.currentVersion,
        payload: payload)
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
      loadOrigin = .user
      alerts.replaceLoad()
      tab.load(url)
      content.window?.makeFirstResponder(tab.webView)

    case .refused(let refusal):
      content.markAddress(invalid: true)
      loadOrigin = .user
      post(.warning, refusal.message(for: address))
    }
  }

  func goBack() {
    loadOrigin = .user
    report(tab.goBack(), doing: "go back", because: "going there")
  }

  func goForward() {
    loadOrigin = .user
    report(tab.goForward(), doing: "go forward", because: "going there")
  }

  func reload() {
    loadOrigin = .user
    report(tab.reload(), doing: "reload", because: "reloading")
  }

  var canGoBack: Bool { tab.canGoBack }
  var canGoForward: Bool { tab.canGoForward }

  /// Moves the keyboard to the address bar and selects its text.
  func openLocation() {
    content.focusAddress()
  }

  /// A move that would send a form again is refused until the browser can ask first.
  private func report(_ move: HistoryMove, doing action: String, because gerund: String) {
    switch move {
    case .moved, .unavailable:
      return

    case .refusedResubmit:
      post(
        .warning,
        "Did not \(action). The page came from a form, and \(gerund) would send the form again.")

    case .refused(let refusal, let address):
      post(.warning, refusal.message(for: address))
    }
  }

  // MARK: Tab events

  func tabDidChange(_ tab: BrowserTab) {
    content.show(
      canGoBack: tab.canGoBack, canGoForward: tab.canGoForward, isLoading: tab.isLoading)

    content.show(securityWarning: tab.showsSecurityWarning)
    content.show(address: Self.address(of: tab.currentURL))
    refresh()
  }

  func tab(_ tab: BrowserTab, notice level: StatusLevel, text: String) {
    post(level, text)
  }

  private func post(_ level: StatusLevel, _ text: String) {
    guard !closed else { return }

    alerts.deliver(AppletNotice(level, text), origin: loadOrigin, from: self, to: host)
  }

  private static func address(of url: URL?) -> String {
    guard let url, !SecurityIndicator.isBlank(url) else { return "" }

    return url.absoluteString
  }

  // MARK: Display

  private func refresh() {
    guard !closed else { return }

    title =
      tab.pageTitle ?? tab.record.title ?? tab.currentURL?.host(percentEncoded: false)
      ?? Self.untitled

    segments =
      tab.isLoading
      ? [AppletSegment(symbolName: "arrow.triangle.2.circlepath", text: "Loading")] : []

    publishedTabs = AppletTabList(first: AppletTab(id: tab.id, title: title))

    let shown = Shown(title: title, segments: segments, record: tab.record)

    guard shown != lastShown else { return }

    let titleChanged = shown.title != lastShown?.title
    lastShown = shown

    host?.appletDidChange(self)

    if titleChanged { host?.appletTabsDidChange(self) }
  }
}
