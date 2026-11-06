import AppKit
import AppletKit
import BrowserModel
import BrowserTestSupport
import Preferences
import StatusKit
import Synchronization
import Theme
import WebKit
import XCTest

@testable import BrowserApplet

/// Stands in for a tab's navigation delegate and cancels every navigation, so a test reads the
/// address the browser asked WebKit to load without any request leaving the machine. It wakes a
/// waiting test at each decision, so a test never polls or sleeps.
@MainActor
final class NavigationSpy: NSObject, WKNavigationDelegate {
  private(set) var urls: [URL] = []
  private let events = AsyncStream.makeStream(of: Void.self)

  func webView(
    _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
  ) {
    if let url = navigationAction.request.url { urls.append(url) }

    decisionHandler(.cancel)
    events.continuation.yield()
  }

  /// Returns once `count` navigations were decided, or fails after `seconds`.
  func until(
    count: Int, seconds: Int = 30, file: StaticString = #filePath, line: UInt = #line
  ) async {
    if urls.count >= count { return }

    var timedOut = false

    let timer = Task { @MainActor [events] in
      try? await Task.sleep(for: .seconds(seconds))

      guard !Task.isCancelled else { return }

      timedOut = true
      events.continuation.yield()
    }

    defer { timer.cancel() }

    for await _ in events.stream {
      if urls.count >= count { return }

      if timedOut {
        XCTFail("timed out waiting for \(count) navigations", file: file, line: line)
        return
      }
    }
  }
}

/// A search engine a test can change between searches.
@MainActor
private final class EngineBox {
  var value = SearchEngine.duckDuckGo
}

/// The address bar's input: search, the offer of plain HTTP, and the handoff to other apps.
@MainActor
final class BrowserAddressTests: XCTestCase {
  private func offerHarness(
    services: BrowserServices = .testing(), handler: FixtureServer.Handler? = nil
  ) async throws -> BrowserHarness {
    try await BrowserHarness.make(
      services: services, handler: handler ?? { _ in .page(titled: "Offer") })
  }

  // MARK: Search

  /// Catches text that is not an address loading as one, a search that ignores the engine named at
  /// that moment, and a setting change that reaches only the pane that was open when it changed.
  /// Two panes share one closure, as the host's factory gives them. The expected addresses are
  /// written out by hand.
  func testASearchUsesTheEngineNamedAtThatMomentInEveryPane() async throws {
    let engine = EngineBox()
    let services = BrowserServices.testing(engine: { engine.value })
    let first = BrowserApplet(dataStore: .nonPersistent(), services: services)
    let second = BrowserApplet(dataStore: .nonPersistent(), services: services)
    defer {
      first.close()
      second.close()
    }

    let spyOne = NavigationSpy()
    let spyTwo = NavigationSpy()
    first.tab.webView.navigationDelegate = spyOne
    second.tab.webView.navigationDelegate = spyTwo

    first.submit(address: "swift concurrency")
    await spyOne.until(count: 1)

    engine.value = .kagi

    second.submit(address: "a&b")
    first.submit(address: "devbox")
    await spyTwo.until(count: 1)
    await spyOne.until(count: 2)

    XCTAssertEqual(
      spyOne.urls.map(\.absoluteString),
      ["https://duckduckgo.com/?q=swift%20concurrency", "https://kagi.com/search?q=devbox"])
    XCTAssertEqual(spyTwo.urls.map(\.absoluteString), ["https://kagi.com/search?q=a%26b"])
  }

  /// Catches an address that searches, and one that never reaches the engine. Addresses load as
  /// typed and a search leaves the address bar's mark clear.
  func testAddressesLoadAndSearchesDoNotMarkTheBar() async throws {
    let applet = BrowserApplet(dataStore: .nonPersistent(), services: .testing())
    defer { applet.close() }

    let spy = NavigationSpy()
    applet.tab.webView.navigationDelegate = spy

    applet.submit(address: "devbox:8080/x")
    applet.submit(address: "devbox/")
    applet.submit(address: "two words")
    await spy.until(count: 3)

    XCTAssertEqual(
      spy.urls.map(\.absoluteString),
      [
        "https://devbox:8080/x", "https://devbox/",
        "https://duckduckgo.com/?q=two%20words",
      ])
    XCTAssertFalse(applet.content.addressIsInvalid)
  }

  // MARK: Plain HTTP offer

  /// Catches an assumed-HTTPS load that cannot connect failing with no way forward, and one that
  /// downgrades by itself. A plain listener answers the TLS handshake with nothing, which is the
  /// server that does not speak TLS. The pane shows the offer and says the connection will be
  /// unencrypted. The server sees no request until the user chooses Load over HTTP, and then it
  /// sees one. The loopback fixture stands in for a remote host, so the load is built the way
  /// the address bar builds it for one, with the scheme assumed.
  func testAnAssumedHTTPSLoadThatCannotConnectOffersHTTPAndNothingDowngradesWithoutIt()
    async throws
  {
    let harness = try await offerHarness()
    defer { harness.stop() }

    let secure = try XCTUnwrap(URL(string: "https://127.0.0.1:\(harness.server.port)/"))
    harness.tab.load(secure, assumed: AssumedLoad(url: secure, typed: harness.server.address()))

    await harness.host.until("the offer shows") {
      !harness.applet.content.errorPage.isHidden
    }

    XCTAssertEqual(
      harness.tab.errorPage, .offerHTTP(host: "127.0.0.1", typed: harness.server.address()))
    XCTAssertEqual(harness.applet.content.errorPage.actionButton.title, "Load over HTTP")
    XCTAssertFalse(harness.applet.content.errorPage.actionButton.isHidden)
    XCTAssertTrue(
      harness.applet.content.errorPage.detailLabel.stringValue.contains("unencrypted"))
    XCTAssertTrue(harness.server.requests.isEmpty, "the load downgraded by itself")
    XCTAssertTrue(harness.posts.isEmpty, "the status bar repeated what the pane says")
    XCTAssertEqual(harness.records.count, 1)
    XCTAssertEqual(harness.records.first?.level, .warning)

    harness.applet.loadOverHTTP()

    await harness.host.until("the page loads over HTTP") {
      harness.applet.title == "Offer" && !harness.applet.tab.isLoading
    }

    XCTAssertEqual(harness.count("GET", "/"), 1)
    XCTAssertNil(harness.tab.errorPage)
    XCTAssertTrue(harness.applet.content.errorPage.isHidden)
    XCTAssertEqual(harness.tab.webView.url?.scheme, "http")
  }

  /// Catches a closed port, the other connection failure the proposal names, failing without the
  /// offer.
  func testAClosedPortOffersHTTPToo() async throws {
    let harness = try await offerHarness()
    defer { harness.stop() }

    let closed = try FixtureServer.closedPort()
    let secure = try XCTUnwrap(URL(string: "https://127.0.0.1:\(closed)/"))
    harness.tab.load(secure, assumed: AssumedLoad(url: secure, typed: "127.0.0.1:\(closed)"))

    await harness.host.until("the offer shows") { harness.tab.errorPage?.offersHTTP == true }
  }

  /// Catches a certificate failure that reaches the offer, which would let a user click past a
  /// server that failed to prove who it is. The TLS fixture presents a self-signed certificate.
  /// The browser installs no trust override, so the load fails. The pane shows the certificate
  /// error with no action, and Load over HTTP does nothing even when called.
  func testACertificateFailureShowsTheErrorAndNeverTheOffer() async throws {
    let harness = try await offerHarness()
    defer { harness.stop() }

    let tls = try await FixtureServer.start(mode: .tls)
    defer { tls.stop() }

    harness.tab.load(tls.url("/"), assumed: AssumedLoad(url: tls.url("/"), typed: tls.address()))

    await harness.host.until("the certificate error shows") {
      !harness.applet.content.errorPage.isHidden
    }

    guard case .certificate(let host, let reason)? = harness.tab.errorPage else {
      return XCTFail(
        "expected a certificate error, got \(String(describing: harness.tab.errorPage))")
    }

    XCTAssertEqual(host, "127.0.0.1")
    XCTAssertFalse(reason.isEmpty)
    XCTAssertTrue(harness.applet.content.errorPage.actionButton.isHidden)
    XCTAssertTrue(harness.applet.content.errorPage.titleLabel.stringValue.contains("not trusted"))
    XCTAssertTrue(tls.requests.isEmpty, "a request went through a failed handshake")

    let before = harness.tab.errorPage

    harness.applet.loadOverHTTP()

    XCTAssertEqual(harness.tab.errorPage, before)
    XCTAssertFalse(harness.tab.webView.isLoading)
    XCTAssertTrue(harness.server.requests.isEmpty)
  }

  /// Catches an explicit `https://` getting the offer. The user typed the scheme, so the browser
  /// did not assume it, and a failure is a plain warning.
  func testAnExplicitHTTPSAddressNeverGetsTheOffer() async throws {
    let harness = try await offerHarness()
    defer { harness.stop() }

    harness.applet.submit(address: "https://127.0.0.1:\(harness.server.port)/")

    await harness.host.until("the failure is reported") { !harness.posts.isEmpty }

    XCTAssertNil(harness.tab.errorPage)
    XCTAssertTrue(harness.applet.content.errorPage.isHidden)
    XCTAssertEqual(harness.posts.first?.level, .warning)
    XCTAssertTrue(harness.posts.first?.text.contains("Could not load") ?? false)
    XCTAssertTrue(harness.server.requests.isEmpty)
  }

  /// Catches an offer for an address the user did not type. A failure at another server than the
  /// one the browser assumed, as after a redirect, is a plain warning.
  func testAFailureAtAnotherServerThanTheAssumedOneGetsNoOffer() async throws {
    let harness = try await offerHarness()
    defer { harness.stop() }

    let assumed = try XCTUnwrap(URL(string: "https://127.0.0.1:\(harness.server.port)/"))
    let other = try XCTUnwrap(URL(string: "https://127.0.0.1:\(try FixtureServer.closedPort())/"))
    harness.tab.load(other, assumed: AssumedLoad(url: assumed, typed: "127.0.0.1"))

    await harness.host.until("the failure is reported") { !harness.posts.isEmpty }

    XCTAssertNil(harness.tab.errorPage)
  }

  /// Catches a host under HSTS getting the offer. The list holds `localhost`, so the same failure
  /// that offers HTTP for another host is a plain warning here. A second store without the host is
  /// the control, so the test fails when the list is ignored and not when `localhost` misbehaves.
  func testAHostUnderHSTSNeverGetsTheOffer() async throws {
    let covered = HSTSStore()
    covered.record(host: "localhost", header: "max-age=3600")

    let harness = try await offerHarness(services: .testing(hsts: covered))
    defer { harness.stop() }

    let secure = try XCTUnwrap(URL(string: "https://localhost:\(harness.server.port)/"))
    harness.tab.load(secure, assumed: AssumedLoad(url: secure, typed: "localhost"))

    await harness.host.until("the failure is reported") { !harness.posts.isEmpty }

    XCTAssertNil(harness.tab.errorPage)

    let control = try await offerHarness()
    defer { control.stop() }

    let again = try XCTUnwrap(URL(string: "https://localhost:\(control.server.port)/"))
    control.tab.load(again, assumed: AssumedLoad(url: again, typed: "localhost"))

    await control.host.until("the offer shows") { control.tab.errorPage?.offersHTTP == true }
  }

  /// Catches Reload on an error page doing nothing, or Reload that drops the assumed scheme so the
  /// retry could never offer again. The retry runs the same load and fails the same way.
  func testReloadOnTheErrorPageTriesTheSameLoadAgain() async throws {
    let harness = try await offerHarness()
    defer { harness.stop() }

    let closed = try FixtureServer.closedPort()
    let secure = try XCTUnwrap(URL(string: "https://127.0.0.1:\(closed)/"))
    harness.tab.load(secure, assumed: AssumedLoad(url: secure, typed: "127.0.0.1:\(closed)"))
    await harness.host.until("the offer shows") { harness.tab.errorPage != nil }

    harness.applet.reload()

    XCTAssertNil(harness.tab.errorPage, "the retry did not begin")

    await harness.host.until("the offer shows again") { harness.tab.errorPage != nil }
  }

  // MARK: The address bar's mark

  /// Catches an invalid mark that is invisible, hidden from assistive technology, or stuck after
  /// an edit. The text turns red, the field's label says it is invalid, and any edit clears both.
  func testTheInvalidMarkIsVisibleAccessibleAndClearedOnEdit() async throws {
    let harness = try await offerHarness()
    defer { harness.stop() }

    let field = harness.applet.content.addressField

    harness.applet.submit(address: "file:///etc/hosts")

    XCTAssertTrue(harness.applet.content.addressIsInvalid)
    XCTAssertEqual(field.accessibilityLabel(), "Address, invalid")
    XCTAssertEqual(field.accessibilityHelp(), "This address cannot be loaded.")
    XCTAssertEqual(field.textColor, ThemePalette.latte[.red].nsColor)

    field.stringValue = "file:///etc/host"
    harness.applet.content.controlTextDidChange(
      Notification(name: NSControl.textDidChangeNotification, object: field))

    XCTAssertFalse(harness.applet.content.addressIsInvalid)
    XCTAssertEqual(field.accessibilityLabel(), "Address")
    XCTAssertNil(field.accessibilityHelp())
    XCTAssertEqual(field.textColor, ThemePalette.latte[.text].nsColor)
  }

  // MARK: Handoff to other apps

  /// Catches a typed `mailto:` that asks, or does not open. It opens the mail app at once, with no
  /// question, and leaves the bar clean.
  func testATypedMailtoOpensTheMailAppWithoutAsking() async throws {
    let opener = FakeOpener()
    let harness = try await offerHarness(services: .testing(opener: opener))
    defer { harness.stop() }

    harness.applet.submit(address: "mailto:a@example.com")

    XCTAssertEqual(opener.opened, [try XCTUnwrap(URL(string: "mailto:a@example.com"))])
    XCTAssertTrue(harness.host.recording.confirmations.isEmpty)
    XCTAssertTrue(harness.posts.isEmpty)
    XCTAssertFalse(harness.applet.content.addressIsInvalid)
  }

  /// Catches a typed address for another app that opens without the user's yes, a question that
  /// does not name the app and the address, and an answer of no that opens anyway.
  func testATypedAddressForAnotherAppAsksFirstAndOpensOnlyOnYes() async throws {
    let opener = FakeOpener()
    let harness = try await offerHarness(services: .testing(opener: opener))
    defer { harness.stop() }

    harness.host.recording.answer = false
    harness.applet.submit(address: "ssh://host.example")

    await harness.host.until("the question is asked") {
      harness.host.recording.confirmations.count == 1 && !harness.tab.isAskingToOpenApp
    }

    let question = try XCTUnwrap(harness.host.recording.confirmations.first)

    XCTAssertEqual(question.title, "Open Terminal?")
    XCTAssertTrue(question.detail.contains("ssh://host.example"))
    XCTAssertTrue(opener.opened.isEmpty, "a no opened the app")

    harness.host.recording.answer = true
    harness.applet.submit(address: "ssh://host.example")

    await harness.host.until("the app opens") { !opener.opened.isEmpty }

    XCTAssertEqual(opener.opened, [try XCTUnwrap(URL(string: "ssh://host.example"))])
  }

  /// Catches a typed address no app handles loading, leaving the page, staying quiet, or leaving
  /// the bar unmarked. One warning says why, the page stays, and no question is asked.
  func testATypedSchemeNoAppHandlesLoadsNothingAndMarksTheBar() async throws {
    let opener = FakeOpener()
    let harness = try await offerHarness(services: .testing(opener: opener))
    defer { harness.stop() }

    await harness.load("/", expecting: "Offer")

    let shown = harness.tab.webView.url

    harness.host.recording.forgetSent()
    harness.applet.submit(address: "nosuchapp://x")

    XCTAssertEqual(harness.posts.count, 1)
    XCTAssertEqual(harness.posts.first?.level, .warning)
    XCTAssertTrue(harness.posts.first?.text.contains("No app handles nosuchapp:") ?? false)
    XCTAssertTrue(harness.applet.content.addressIsInvalid)
    XCTAssertTrue(opener.opened.isEmpty)
    XCTAssertTrue(harness.host.recording.confirmations.isEmpty)
    XCTAssertEqual(harness.tab.webView.url, shown)
  }

  /// Catches a failed open that goes unreported, and one that clears the user's text.
  func testAnOpenThatFailsPostsAWarning() async throws {
    let opener = FakeOpener()
    opener.succeeds = false

    let harness = try await offerHarness(services: .testing(opener: opener))
    defer { harness.stop() }

    harness.applet.submit(address: "mailto:a@example.com")

    XCTAssertEqual(harness.posts.count, 1)
    XCTAssertTrue(harness.posts.first?.text.contains("Could not open") ?? false)
    XCTAssertTrue(harness.applet.content.addressIsInvalid)
  }

  private nonisolated static func linkPage() -> FixtureServer.Handler {
    { _ in
      .page(
        titled: "Links",
        body:
          "<a id=ssh href='ssh://host.example/x'>ssh</a><a id=mail href='mailto:a@example.com'>m</a>"
          + "<a id=none href='nosuchapp://x'>none</a>")
    }
  }

  /// A real left mouse-up through the web view's own handler, built from a `CGEvent` as the
  /// button tests build theirs. A real click on the screen cannot be made in a package test, so
  /// the handler is the nearest point the test can drive.
  private func mouseUp(in tab: BrowserTab) throws {
    let cgEvent = try XCTUnwrap(
      CGEvent(
        mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: .zero,
        mouseButton: .left))

    try XCTUnwrap(tab.webView as? BrowserWebView).mouseUp(
      with: try XCTUnwrap(NSEvent(cgEvent: cgEvent)))
  }

  private func linkHarness(
    opener: FakeOpener, clock: ClockBox
  ) async throws -> BrowserHarness {
    let harness = try await offerHarness(
      services: .testing(opener: opener, clock: { clock.now }), handler: Self.linkPage())

    await harness.load("/", expecting: "Links")
    harness.host.recording.forgetSent()

    return harness
  }

  /// Catches a followed link for another app that opens without a yes, a question that does not
  /// name both, and a no that opens. The click is a real mouse-up through the view's handler. The
  /// page stays where it was, and no load starts.
  func testAClickedLinkForAnotherAppAsksAndOpensOnlyOnYes() async throws {
    let opener = FakeOpener()
    let harness = try await linkHarness(opener: opener, clock: ClockBox())
    defer { harness.stop() }

    let shown = harness.tab.webView.url

    harness.host.recording.answer = false
    try mouseUp(in: harness.tab)
    await harness.run("document.getElementById('ssh').click()")
    await harness.host.until("the question is asked and answered") {
      harness.host.recording.confirmations.count == 1 && !harness.tab.isAskingToOpenApp
    }

    let question = try XCTUnwrap(harness.host.recording.confirmations.first)

    XCTAssertEqual(question.title, "Open Terminal?")
    XCTAssertTrue(question.detail.contains("ssh://host.example/x"))
    XCTAssertTrue(opener.opened.isEmpty)
    XCTAssertEqual(harness.tab.webView.url, shown)
    XCTAssertEqual(harness.applet.title, "Links")

    harness.host.recording.answer = true
    try mouseUp(in: harness.tab)
    await harness.run("document.getElementById('ssh').click()")
    await harness.host.until("the app opens") { !opener.opened.isEmpty }

    XCTAssertEqual(opener.opened, [try XCTUnwrap(URL(string: "ssh://host.example/x"))])
    XCTAssertEqual(harness.tab.webView.url, shown)
  }

  /// Catches a clicked `mailto:` link that asks, which the proposal says it does not.
  func testAClickedMailtoLinkOpensTheMailAppWithoutAsking() async throws {
    let opener = FakeOpener()
    let harness = try await linkHarness(opener: opener, clock: ClockBox())
    defer { harness.stop() }

    try mouseUp(in: harness.tab)
    await harness.run("document.getElementById('mail').click()")
    await harness.host.until("the mail app opens") { !opener.opened.isEmpty }

    XCTAssertTrue(harness.host.recording.confirmations.isEmpty)
    XCTAssertTrue(harness.posts.isEmpty)
  }

  /// Catches a click on a link for a scheme no app handles that asks or opens. One warning says
  /// why.
  func testAClickedLinkNoAppHandlesWarnsAndAsksNothing() async throws {
    let opener = FakeOpener()
    let harness = try await linkHarness(opener: opener, clock: ClockBox())
    defer { harness.stop() }

    try mouseUp(in: harness.tab)
    await harness.run("document.getElementById('none').click()")
    await harness.host.until("the warning posts") { !harness.posts.isEmpty }

    XCTAssertEqual(harness.posts.count, 1)
    XCTAssertTrue(harness.posts.first?.text.contains("No app handles nosuchapp:") ?? false)
    XCTAssertTrue(harness.host.recording.confirmations.isEmpty)
    XCTAssertTrue(opener.opened.isEmpty)
  }

  /// Catches a page that opens an app with no click. WebKit reports a script's `a.click()` as a
  /// followed link, so only a real mouse-up makes one the user's. A scripted click on `mailto:`
  /// and on another app's scheme opens nothing and asks nothing. Repeating it stays refused with
  /// one warning each time and never builds a question, so a page cannot loop one.
  func testAScriptedClickNeverOpensAnAppAndNeverAsks() async throws {
    let opener = FakeOpener()
    let harness = try await linkHarness(opener: opener, clock: ClockBox())
    defer { harness.stop() }

    for _ in 0..<2 {
      for id in ["mail", "ssh"] {
        let before = harness.posts.count

        await harness.run("document.getElementById('\(id)').click()")
        await harness.host.until("the refusal posts") { harness.posts.count == before + 1 }
      }
    }

    XCTAssertEqual(harness.posts.count, 4)
    XCTAssertTrue(harness.posts.allSatisfy { $0.level == .warning })
    XCTAssertTrue(harness.posts.allSatisfy { $0.text.contains("Did not open") })
    XCTAssertTrue(opener.opened.isEmpty, "a script opened an app")
    XCTAssertTrue(harness.host.recording.confirmations.isEmpty, "a script raised a question")
    XCTAssertFalse(harness.tab.isAskingToOpenApp)
  }

  /// Catches a click that can be spent twice. One mouse-up covers the first link decision. A
  /// script's click right after it is refused, and a second real click is needed to ask again.
  func testAClickIsSpentByTheFirstDecision() async throws {
    let opener = FakeOpener()
    let harness = try await linkHarness(opener: opener, clock: ClockBox())
    defer { harness.stop() }

    harness.host.recording.answer = false
    try mouseUp(in: harness.tab)
    await harness.run("document.getElementById('ssh').click()")
    await harness.host.until("the question is answered") {
      harness.host.recording.confirmations.count == 1 && !harness.tab.isAskingToOpenApp
    }

    await harness.run("document.getElementById('ssh').click()")
    await harness.host.until("the second click is refused") { !harness.posts.isEmpty }

    XCTAssertEqual(harness.host.recording.confirmations.count, 1)
    XCTAssertTrue(harness.posts.first?.text.contains("not one") ?? false)
  }

  /// Catches a click that stays good for a page to use later. A mouse-up older than the bound
  /// gives a script's click no help. The clock is the test's, so the bound is exact.
  func testAClickExpiresAfterTheBound() async throws {
    let opener = FakeOpener()
    let clock = ClockBox()
    let harness = try await linkHarness(opener: opener, clock: clock)
    defer { harness.stop() }

    try mouseUp(in: harness.tab)
    clock.advance(by: LinkGesture.bound + 1)
    await harness.run("document.getElementById('ssh').click()")
    await harness.host.until("the stale click is refused") { !harness.posts.isEmpty }

    XCTAssertTrue(harness.host.recording.confirmations.isEmpty)
    XCTAssertTrue(opener.opened.isEmpty)
  }

  /// Catches two questions open in one tab, `mailto:` slipping past the guard, and a question that
  /// blocks the pane. A real click on a second link while one question waits gets a warning and
  /// no second question, and a real click on `mailto:` is refused too. The first question still
  /// answers, and the tab keeps working: a script runs while it waits.
  func testATabAsksOneHandoffQuestionAtATimeAndMailtoWaitsToo() async throws {
    let opener = FakeOpener()
    let harness = try await linkHarness(opener: opener, clock: ClockBox())
    defer { harness.stop() }

    harness.host.recording.holdsQuestions = true

    try mouseUp(in: harness.tab)
    await harness.run("document.getElementById('ssh').click()")
    await harness.host.until("the question waits") {
      harness.host.recording.confirmations.count == 1
    }

    for id in ["ssh", "mail"] {
      let before = harness.posts.count

      try mouseUp(in: harness.tab)
      await harness.run("document.getElementById('\(id)').click()")
      await harness.host.until("the \(id) link is refused") { harness.posts.count == before + 1 }

      XCTAssertTrue(harness.posts.last?.text.contains("already waiting") ?? false, id)
    }

    XCTAssertEqual(harness.host.recording.confirmations.count, 1)
    XCTAssertTrue(opener.opened.isEmpty, "mailto opened past a waiting question")

    let alive = await harness.run("1 + 1") as? Int

    XCTAssertEqual(alive, 2, "the page stopped responding while the question waited")

    harness.host.recording.pendingAnswer?.resume(returning: true)
    await harness.host.until("the app opens") { !opener.opened.isEmpty }

    XCTAssertEqual(opener.opened, [try XCTUnwrap(URL(string: "ssh://host.example/x"))])
  }

  /// Catches a background tab opening an app or raising a question, even with a real click. The
  /// tab is named in the warning, and nothing is asked or opened, `mailto:` included.
  func testABackgroundTabNeverOpensOrAsksAboutAnApp() async throws {
    let opener = FakeOpener()
    let harness = try await linkHarness(opener: opener, clock: ClockBox())
    defer { harness.stop() }

    let background = harness.tab

    harness.applet.openTab()
    harness.host.recording.forgetSent()

    for id in ["ssh", "mail"] {
      let before = harness.posts.count

      try mouseUp(in: background)
      _ = try? await background.webView.evaluateJavaScript(
        "document.getElementById('\(id)').click()")
      await harness.host.until("the \(id) refusal posts") { harness.posts.count == before + 1 }

      XCTAssertTrue(harness.posts.last?.text.contains("In the tab") ?? false, id)
    }

    XCTAssertTrue(harness.host.recording.confirmations.isEmpty)
    XCTAssertTrue(opener.opened.isEmpty)
  }

  // MARK: Error page lifetime

  /// Catches an earlier offer staying over the pane after a later navigation fails without
  /// building a page of its own. The page's script moves to an explicit `https://` address that
  /// cannot connect. That load earns no offer, since the user typed the scheme, so it gets a
  /// plain warning. The old offer must not stay up over it.
  func testAnOfferDoesNotOutliveALaterFailureThatBuildsNoPage() async throws {
    let harness = try await offerHarness()
    defer { harness.stop() }

    await harness.load("/", expecting: "Offer")

    let first = try XCTUnwrap(URL(string: "https://127.0.0.1:\(try FixtureServer.closedPort())/"))
    harness.tab.load(first, assumed: AssumedLoad(url: first, typed: "127.0.0.1"))
    await harness.host.until("the offer shows") { harness.tab.errorPage != nil }

    let second = try FixtureServer.closedPort()
    harness.host.recording.forgetSent()
    await harness.run("location.href = 'https://127.0.0.1:\(second)/'")
    await harness.host.until("the second failure is reported") { !harness.posts.isEmpty }

    XCTAssertNil(harness.tab.errorPage, "the old offer stayed over the pane")
    XCTAssertTrue(harness.applet.content.errorPage.isHidden)
  }

  // MARK: HSTS recording

  /// Stands in for the response WebKit hands the navigation delegate. WebKit builds its own and
  /// gives a test no way to make one, so this answers the three messages the delegate sends. The
  /// test casts it to the WebKit type, which is safe only because the delegate reads those three
  /// properties and nothing else.
  private final class FakeNavigationResponse: NSObject {
    @objc let response: URLResponse
    @objc let isForMainFrame = true
    @objc let canShowMIMEType = true

    init(_ response: URLResponse) {
      self.response = response
    }
  }

  /// Catches the delegate dropping the header. A main-frame HTTPS response with the header puts the
  /// host in the shared list, and the same header over plain HTTP puts nothing there. A self-signed
  /// server never reaches the delegate in a test, so the delegate method is called with a stand-in
  /// response of the test's making. No production code was opened for it.
  func testTheDelegateRecordsTheHeaderFromAMainFrameHTTPSResponse() async throws {
    let hsts = HSTSStore()
    let harness = try await offerHarness(services: .testing(hsts: hsts))
    defer { harness.stop() }

    func respond(from address: String) throws {
      let url = try XCTUnwrap(URL(string: address))
      let response = try XCTUnwrap(
        HTTPURLResponse(
          url: url, statusCode: 200, httpVersion: "HTTP/1.1",
          headerFields: [
            "Strict-Transport-Security": "max-age=100000; includeSubDomains",
            "Content-Type": "text/html",
          ]))

      let fake = unsafeBitCast(FakeNavigationResponse(response), to: WKNavigationResponse.self)

      harness.tab.webView(harness.tab.webView, decidePolicyFor: fake) { _ in }
    }

    try respond(from: "http://plain.example/")
    XCTAssertEqual(hsts.count, 0, "a header over plain HTTP was recorded")

    try respond(from: "https://secure.example/page")

    XCTAssertTrue(hsts.contains(host: "secure.example"))
    XCTAssertTrue(hsts.contains(host: "www.secure.example"))
    XCTAssertFalse(hsts.contains(host: "plain.example"))
  }
}

/// A clock a test moves by hand.
private final class ClockBox: Sendable {
  private let value = Mutex(Date(timeIntervalSince1970: 1_800_000_000))

  var now: Date { value.withLock { $0 } }

  func advance(by seconds: TimeInterval) {
    value.withLock { $0 = $0.addingTimeInterval(seconds) }
  }
}
