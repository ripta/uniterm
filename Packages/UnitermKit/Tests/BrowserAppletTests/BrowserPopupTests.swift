import AppKit
import AppletKit
import BrowserModel
import BrowserTestSupport
import StatusKit
import WebKit
import XCTest

@testable import BrowserApplet

/// New windows against a real web view. A script run through `evaluateJavaScript` counts as a user
/// gesture for WebKit, so `window.open` from the tests is allowed, and a page script that opens a
/// window at load, with no gesture, is blocked by WebKit's own default.
@MainActor
final class BrowserPopupTests: XCTestCase {
  private nonisolated static let handler: FixtureServer.Handler = { request in
    switch request.path {
    case "/opener":
      return FixtureServer.Response(
        status: 200,
        headers: [
          ("Content-Type", "text/html"), ("Cache-Control", "no-store"),
          ("Set-Cookie", "sid=1; Path=/"),
        ],
        body: Data(
          """
          <title>Opener</title>
          <a id=blank target=_blank href=/popup>link</a>
          <button id=go onclick="window.open('/signin')">go</button>
          <script>
          window.addEventListener('message', function (e) { document.title = 'got:' + e.data; });
          </script>
          """.utf8))

    case "/popup":
      return Pages.page("Popup", "<input id=a value=draft>")

    case "/signin":
      return Pages.page(
        "SignIn",
        "<script>window.opener.postMessage('hello', '*'); window.close();</script>")

    case "/plain":
      return Pages.page("Plain")

    case "/redirect-ftp":
      return .redirect(to: "ftp://files.example.invalid/x", status: 302)

    case "/iframe-app":
      return Pages.page(
        "IframeApp", "<iframe id=sub src=/app-link></iframe><a id=main href=\"ssh://host/m\">m</a>")

    case "/app-link":
      return Pages.page("AppLink", "<a id=l href=\"ssh://host/x\">x</a>")

    default:
      return Pages.page("Other")
    }
  }

  private var window: NSWindow?
  private var opener: FakeOpener!

  private func make(dataStore: WKWebsiteDataStore = .nonPersistent()) async throws
    -> BrowserHarness
  {
    let opener = FakeOpener()

    self.opener = opener

    let harness = try await BrowserHarness.make(
      services: .testing(opener: opener), dataStore: dataStore, handler: Self.handler)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
      backing: .buffered, defer: false)

    window.contentView = harness.applet.content
    self.window = window

    return harness
  }

  private func openPopup(_ harness: BrowserHarness, path: String = "/popup") async {
    await harness.run("window.open('\(path)')")
    await harness.host.until("the pop-up tab opens") { harness.applet.tabCount >= 2 }
  }

  /// Catches a link that opens a window with no tab, a tab that is not selected or not placed after
  /// its opener, and one whose web view is not WebKit's, so `window.opener` is gone. The tab is built
  /// at once, and its page is the one WebKit loads.
  func testALinkThatOpensAWindowOpensASelectedTabRightAfterItsOpener() async throws {
    let harness = try await make()
    defer { harness.stop() }

    harness.applet.openTab()
    await harness.load("/opener", expecting: "Opener")
    harness.applet.openTab()
    harness.applet.selectTab(at: 1)

    let opener = harness.tab

    await harness.run("document.getElementById('blank').click()")
    await harness.host.until("the pop-up loads") {
      harness.applet.tabCount == 4 && harness.applet.title == "Popup"
    }

    XCTAssertEqual(harness.applet.selectedTabIndex, 2)
    XCTAssertTrue(harness.applet.tabs[1] === opener)
    XCTAssertTrue(harness.applet.tabs[3] !== harness.tab, "the pop-up went right after its opener")
    XCTAssertTrue(harness.tab.opener === opener)
    XCTAssertTrue(harness.tab.isPopup)
    XCTAssertTrue(harness.tab.isMaterialized)
    XCTAssertTrue(harness.tab.hasBegunLoading)
    XCTAssertEqual(harness.applet.publishedTabs.selected, harness.tab.id)
  }

  /// Catches a pop-up that does not share the browser's store. The pop-up's web view uses the
  /// opener's store, and the cookie the opener's page set reaches the pop-up's request.
  func testThePopUpSharesTheOpenersWebsiteDataStore() async throws {
    let store = WKWebsiteDataStore.nonPersistent()
    let harness = try await make(dataStore: store)
    defer { harness.stop() }

    await harness.load("/opener", expecting: "Opener")
    await openPopup(harness)
    await harness.host.until("the pop-up loads") { harness.applet.title == "Popup" }

    XCTAssertTrue(harness.tab.webView.configuration.websiteDataStore === store)

    let request = try XCTUnwrap(harness.server.requests.last { $0.path == "/popup" })

    XCTAssertEqual(request.headers["cookie"], "sid=1")
  }

  /// Catches the browser letting a script open windows by itself. WKWebView on macOS allows it
  /// unless `javaScriptCanOpenWindowsAutomatically` is false, which is not WebKit's default there. A
  /// test cannot make a script run without a gesture, since `evaluateJavaScript` and
  /// `callAsyncJavaScript` both carry one, and a gesture lapses only after a second of real time.
  /// The test pins the preference on a tab's web view and on a pop-up's.
  func testTheBrowserPinsTheWindowOpenPreferenceThatBlocksAScriptWithNoGesture() async throws {
    let harness = try await make()
    defer { harness.stop() }

    XCTAssertFalse(
      harness.tab.webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically)

    await harness.load("/plain", expecting: "Plain")
    await openPopup(harness)

    XCTAssertTrue(harness.tab.isPopup)
    XCTAssertFalse(
      harness.tab.webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically)
  }

  /// Catches a page that opens tabs without end. WebKit lets a script that holds a gesture open as
  /// many windows as it asks for. The pane stops at its limit, says so once, and `window.open`
  /// returns null for the rest. Closing a pop-up makes room, and the warning can be heard again.
  func testAPageCannotOpenMoreThanTheLimitOfTabs() async throws {
    let harness = try await make()
    defer { harness.stop() }

    await harness.load("/plain", expecting: "Plain")
    harness.host.recording.forgetSent()

    let opened = try await harness.tab.webView.evaluateJavaScript(
      """
      var count = 0;
      for (var i = 0; i < 40; i++) { if (window.open('/popup')) { count += 1; } }
      count
      """)

    XCTAssertEqual(opened as? Int, BrowserApplet.popupLimit)
    XCTAssertEqual(harness.applet.tabCount, 1 + BrowserApplet.popupLimit)
    XCTAssertEqual(harness.posts.filter { $0.level == .warning }.count, 1)
  }

  /// Catches the limit on script-opened tabs counting tabs the user opened. A real click on a
  /// `target=_blank` link opens a tab however many are open, keeps `window.opener`, and never
  /// warns. The limit then still holds for a script, whose count starts from zero.
  func testRealClicksPastTheLimitStillOpenTabsAndTheLimitStillHoldsForAScript() async throws {
    let harness = try await make()
    defer { harness.stop() }

    await harness.load("/opener", expecting: "Opener")

    let opener = harness.tab
    let clicks = BrowserApplet.popupLimit + 2

    harness.host.recording.forgetSent()

    for index in 1...clicks {
      opener.noteMouseUp()

      _ = try await opener.webView.evaluateJavaScript(
        "document.getElementById('blank').click(); void 0")
      await harness.host.until("the tab for click \(index) opens") {
        harness.applet.tabCount == index + 1
      }
    }

    XCTAssertEqual(harness.applet.tabCount, clicks + 1)
    XCTAssertTrue(harness.applet.tabs.dropFirst().allSatisfy { $0.isPopup && $0.opener === opener })
    XCTAssertEqual(harness.posts.filter { $0.level == .warning }.count, 0, "\(harness.posts)")

    let scripted = try await opener.webView.evaluateJavaScript(
      """
      var count = 0;
      for (var i = 0; i < 40; i++) { if (window.open('/popup')) { count += 1; } }
      count
      """)

    XCTAssertEqual(scripted as? Int, BrowserApplet.popupLimit)
    XCTAssertEqual(harness.applet.tabCount, clicks + 1 + BrowserApplet.popupLimit)
    XCTAssertEqual(harness.posts.filter { $0.level == .warning }.count, 1)
  }

  /// Catches a menu choice that is not the user's. The rewritten item runs the action WebKit gave
  /// it, after telling the web view the user chose it, so the tab it opens never counts toward the
  /// script limit.
  func testAChosenNewTabItemTellsTheViewTheUserChoseItAndRunsWebKitsAction() {
    final class Target: NSObject {
      var ran = 0

      @objc func openLink(_ sender: Any?) { ran += 1 }
    }

    let target = Target()
    let menu = NSMenu()
    let item = NSMenuItem(
      title: "Open Link in New Window", action: #selector(Target.openLink(_:)), keyEquivalent: "")

    item.target = target
    item.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierOpenLinkInNewWindow")
    menu.addItem(item)

    let other = NSMenuItem(
      title: "Copy Link", action: #selector(Target.openLink(_:)), keyEquivalent: "")

    other.target = target
    other.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierCopyLink")
    menu.addItem(other)

    var chosen = 0
    let forwarders = NewTabMenu.rewrite(menu) { chosen += 1 }

    XCTAssertEqual(forwarders.count, 1)
    XCTAssertTrue(other.target === target, "an item that is not a new-window item was rewired")

    _ = item.target?.perform(item.action, with: item)

    XCTAssertEqual(chosen, 1)
    XCTAssertEqual(target.ran, 1)
  }

  /// Catches a sign-in flow that loses its opener. The pop-up posts to `window.opener` and closes
  /// itself. The opener gets the message, the pop-up's tab is gone, and the selection is back on the
  /// opener.
  func testASignInPopUpPostsBackToItsOpenerAndClosesItself() async throws {
    let harness = try await make()
    defer { harness.stop() }

    await harness.load("/opener", expecting: "Opener")
    await harness.run("document.getElementById('go').click()")
    await harness.host.until("the opener hears the pop-up and the tab is gone") {
      harness.applet.title == "got:hello" && harness.applet.tabCount == 1
    }

    XCTAssertEqual(harness.applet.selectedTabIndex, 0)
    XCTAssertTrue(
      harness.applet.closedTabStamps.isEmpty, "a sign-in address is not kept for reopen")
  }

  /// Catches a selection that goes to the closed tab's neighbour. A pop-up that closes itself
  /// returns the selection to its opener while the opener exists. An unselected pop-up that
  /// closes leaves the selection alone.
  func testSelectionReturnsToTheOpenerAndOnlyWhenThePopUpWasSelected() async throws {
    let harness = try await make()
    defer { harness.stop() }

    await harness.load("/opener", expecting: "Opener")
    harness.applet.openTab()
    harness.applet.selectTab(at: 0)

    let opener = harness.tab

    await openPopup(harness)
    await harness.host.until("the pop-up loads") { harness.applet.title == "Popup" }

    XCTAssertEqual(harness.applet.tabCount, 3)
    XCTAssertEqual(harness.applet.selectedTabIndex, 1)

    let popup = harness.tab

    harness.applet.tabDidRequestClose(popup)

    XCTAssertEqual(harness.applet.tabCount, 2)
    XCTAssertTrue(harness.tab === opener, "the neighbour was selected, not the opener")

    await openPopup(harness)
    await harness.host.until("the pop-up loads again") { harness.applet.title == "Popup" }

    let second = harness.tab

    harness.applet.selectTab(at: 2)

    let others = harness.tab

    harness.applet.tabDidRequestClose(second)

    XCTAssertEqual(harness.applet.tabCount, 2)
    XCTAssertTrue(harness.tab === others, "an unselected pop-up closed and moved the selection")
  }

  /// Catches a script closing the last tab or the pane. A pop-up left alone, because its opener was
  /// closed, stays.
  func testAScriptNeverClosesTheLastTab() async throws {
    let harness = try await make()
    defer { harness.stop() }

    await harness.load("/opener", expecting: "Opener")
    await openPopup(harness)
    await harness.host.until("the pop-up loads") { harness.applet.title == "Popup" }

    let closed = await harness.applet.closeTab(at: 0)

    XCTAssertEqual(closed, .closed)
    XCTAssertEqual(harness.applet.tabCount, 1)
    XCTAssertTrue(harness.tab.isPopup)

    harness.applet.tabDidRequestClose(harness.tab)

    XCTAssertEqual(harness.applet.tabCount, 1)
    XCTAssertFalse(harness.host.recording.exited)
  }

  /// Catches a script closing a tab that holds input the user would be asked about. The tab stays
  /// open and the user is told. A real typed edit in the pop-up marks the pop-up, not its opener,
  /// since each web view has its own tracker.
  func testAScriptCannotCloseAPopUpThatHoldsInput() async throws {
    let harness = try await make()
    defer { harness.stop() }

    await harness.load("/opener", expecting: "Opener")
    await openPopup(harness)
    await harness.host.until("the pop-up loads") { harness.applet.title == "Popup" }

    let popup = harness.tab

    window?.makeFirstResponder(popup.webView)
    await harness.run("var e = document.getElementById('a'); e.focus(); e.select()")
    (popup.webView as? any NSTextInputClient)?.insertText(
      "typed", replacementRange: NSRange(location: NSNotFound, length: 0))
    await harness.host.until("the pop-up is marked") { popup.hasUnsentInput }

    XCTAssertFalse(harness.applet.tabs[0].hasUnsentInput)

    harness.host.recording.forgetSent()
    harness.applet.tabDidRequestClose(popup)

    XCTAssertEqual(harness.applet.tabCount, 2)
    XCTAssertEqual(harness.posts.count, 1)
    XCTAssertEqual(harness.posts.first?.level, .warning)
  }

  /// Catches a pop-up from a tab the user is not looking at taking the selection or the keyboard.
  /// It opens right after its opener, stays unselected, and a notice names the opener.
  func testAPopUpFromABackgroundTabDoesNotStealTheSelection() async throws {
    let harness = try await make()
    defer { harness.stop() }

    await harness.load("/opener", expecting: "Opener")

    let background = harness.tab

    harness.applet.openTab()

    let foreground = harness.tab

    harness.host.recording.forgetSent()

    _ = try await background.webView.evaluateJavaScript("window.open('/popup'); void 0")
    await harness.host.until("the pop-up tab exists") { harness.applet.tabCount == 3 }

    XCTAssertTrue(harness.tab === foreground)
    XCTAssertEqual(harness.applet.selectedTabIndex, 2)
    XCTAssertTrue(harness.applet.tabs[1].isPopup)
    XCTAssertTrue(harness.applet.tabs[1].opener === background)
    XCTAssertEqual(harness.posts.count, 1)
    XCTAssertTrue(harness.posts[0].text.contains("In the tab"), harness.posts[0].text)
    XCTAssertTrue(harness.posts[0].text.contains("new tab in the background"))
  }

  /// Catches a pop-up whose first load skips the scheme gate. A window to a scheme the browser does
  /// not load opens nothing and warns. A pop-up that redirects to such a scheme is stopped by the
  /// gate in its own navigation delegate, so the pop-up's observers and gates work although
  /// WebKit built its web view.
  func testAPopUpsFirstLoadPassesTheSchemeGate() async throws {
    let harness = try await make()
    defer { harness.stop() }

    await harness.load("/opener", expecting: "Opener")

    for address in ["file:///etc/hosts", "javascript:1", "data:text/html,x", "ssh://host/x"] {
      harness.host.recording.forgetSent()

      _ = try await harness.tab.webView.evaluateJavaScript(
        "window.__w = window.open('\(address)'); void 0")
      await harness.host.until("the refusal is reported for \(address)") {
        !harness.posts.isEmpty
      }

      XCTAssertEqual(harness.applet.tabCount, 1, address)
      XCTAssertEqual(harness.posts.first?.level, .warning, address)
    }

    harness.host.recording.forgetSent()

    await openPopup(harness, path: "/redirect-ftp")
    await harness.host.until("the redirect is refused") { !harness.posts.isEmpty }

    XCTAssertEqual(harness.posts.count, 1)
    XCTAssertEqual(harness.posts.first?.level, .warning)
    XCTAssertTrue(opener.opened.isEmpty)
  }

  /// Catches a script or iframe that launches an app, or asks, with no click of the user's. A
  /// script in a subframe opens `ssh:` and a script in the main frame opens `mailto:`. Neither
  /// opens a tab, asks, or launches. A script's click in the frame is refused too.
  func testScriptsAndIframesNeverLaunchOrAskAboutAnApp() async throws {
    let harness = try await make()
    defer { harness.stop() }

    await harness.load("/iframe-app", expecting: "IframeApp")

    harness.host.recording.forgetSent()

    _ = try await harness.tab.webView.evaluateJavaScript(
      "document.getElementById('sub').contentWindow.open('ssh://host/y'); void 0")
    await harness.host.until("the subframe's window is refused") { !harness.posts.isEmpty }

    harness.host.recording.forgetSent()

    _ = try await harness.tab.webView.evaluateJavaScript("window.open('mailto:a@b.c'); void 0")
    await harness.host.until("the script's mailto is refused") { !harness.posts.isEmpty }

    XCTAssertEqual(harness.applet.tabCount, 1)
    XCTAssertEqual(harness.host.recording.confirmations.count, 0)
    XCTAssertTrue(opener.opened.isEmpty)
  }

  /// Catches a real click inside an iframe asking to open an app. WebKit reports the click as a
  /// followed link, and the view saw a real mouse-up, but the link belongs to a frame the page
  /// chose. It is refused with a notice. The same real click on a main-frame link asks, so the test
  /// can tell the two apart.
  func testARealClickInAnIframeNeverAsksToOpenAnApp() async throws {
    let harness = try await make()
    defer { harness.stop() }

    await harness.load("/iframe-app", expecting: "IframeApp")

    harness.host.recording.forgetSent()
    harness.tab.noteMouseUp()

    _ = try await harness.tab.webView.evaluateJavaScript(
      "document.getElementById('sub').contentDocument.getElementById('l').click(); void 0")
    await harness.host.until("the iframe's link is refused") { !harness.posts.isEmpty }

    XCTAssertEqual(harness.host.recording.confirmations.count, 0)
    XCTAssertTrue(opener.opened.isEmpty)
    XCTAssertEqual(harness.posts.first?.level, .warning)

    harness.host.recording.forgetSent()
    harness.host.recording.holdsQuestions = true
    harness.tab.noteMouseUp()

    _ = try await harness.tab.webView.evaluateJavaScript(
      "document.getElementById('main').click(); void 0")
    await harness.host.until("the main frame's link asks") {
      !harness.host.recording.confirmations.isEmpty
    }

    harness.host.recording.pendingAnswer?.resume(returning: false)
  }

  // MARK: Menu

  /// Catches a context menu that still offers a new window, and a rewrite that depends on a
  /// title. Items are found by identifier. An item with no identifier keeps its title, even when
  /// the title says window.
  func testTheContextMenuOffersNewTabsByIdentifier() {
    let menu = NSMenu()
    let rewritten: [(String, String)] = [
      ("WKMenuItemIdentifierOpenLinkInNewWindow", "Open Link in New Tab"),
      ("WKMenuItemIdentifierOpenImageInNewWindow", "Open Image in New Tab"),
      ("WKMenuItemIdentifierOpenFrameInNewWindow", "Open Frame in New Tab"),
      ("WKMenuItemIdentifierOpenMediaInNewWindow", "Open Media in New Tab"),
    ]

    for (identifier, _) in rewritten {
      let item = NSMenuItem(title: "In einem neuen Fenster öffnen", action: nil, keyEquivalent: "")

      item.identifier = NSUserInterfaceItemIdentifier(identifier)
      menu.addItem(item)
    }

    let copy = NSMenuItem(title: "Copy Link", action: nil, keyEquivalent: "")

    copy.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierCopyLink")
    menu.addItem(copy)

    let stranger = NSMenuItem(title: "Open Link in New Window", action: nil, keyEquivalent: "")

    menu.addItem(stranger)

    _ = NewTabMenu.rewrite(menu) {}

    XCTAssertEqual(menu.items.prefix(4).map(\.title), rewritten.map(\.1))
    XCTAssertEqual(copy.title, "Copy Link")
    XCTAssertEqual(stranger.title, "Open Link in New Window")
  }

  /// Catches a web view whose menu hook never runs the rewrite.
  func testTheWebViewRunsTheRewriteWhenItsMenuOpens() async throws {
    let harness = try await make()
    defer { harness.stop() }

    let menu = NSMenu()
    let item = NSMenuItem(title: "Open Link in New Window", action: nil, keyEquivalent: "")

    item.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierOpenLinkInNewWindow")
    menu.addItem(item)

    let event = try XCTUnwrap(
      NSEvent.mouseEvent(
        with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1,
        pressure: 1))

    harness.tab.webView.willOpenMenu(menu, with: event)

    XCTAssertEqual(menu.item(withTitle: "Open Link in New Tab")?.identifier, item.identifier)
  }
}
