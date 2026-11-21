import AppKit
import AppletKit
import BrowserModel
import BrowserTestSupport
import StatusKit
import WebKit
import XCTest

@testable import BrowserApplet

/// A controller's commands against a real browser and a local server, through shared dispatch.
///
/// The dispatcher is the same one a window uses, stepped by hand. These prove what the browser
/// owns: which tabs a grant owns, which moves it refuses, and that a controller's tab asks before
/// anything reaches another app or the disk. They cannot prove how a window finds the caller's
/// powers. The window's and the script host's tests prove that.
@MainActor
final class BrowserRemoteTests: XCTestCase {
  private nonisolated static let pages: FixtureServer.Handler = { request in
    switch (request.method, request.path) {
    case ("GET", "/form"):
      return Pages.page("Form", "<form method=post action=/result><input name=a value=1></form>")

    case ("POST", "/result"):
      return Pages.page("Posted")

    case ("GET", "/file"):
      return FixtureServer.Response(
        status: 200,
        headers: [
          ("Content-Type", "application/octet-stream"),
          ("Content-Disposition", "attachment; filename=\"got.txt\""),
        ], body: Data("x".utf8))

    case ("GET", "/draft"):
      return Pages.page("Draft", "<input id=a value=draft>")

    default:
      return Pages.page(String(request.path.dropFirst()).uppercased())
    }
  }

  private let grant = AppletCaller(grant: "connection 1")
  private let other = AppletCaller(grant: "connection 2")
  private var turns: [@MainActor () -> Void] = []

  private lazy var dispatcher = ControlDispatcher { [weak self] body in self?.turns.append(body) }

  private func make(
    hosting: BrowserHarness.Hosting = .window, services: BrowserServices = .testing()
  ) async throws -> BrowserHarness {
    try await BrowserHarness.make(services: services, hosting: hosting, handler: Self.pages)
  }

  /// Sends one command and runs the queue. A tab given by `on` rides as the command's target.
  @discardableResult
  private func send(
    _ harness: BrowserHarness, _ name: String, _ arguments: [String: JSONValue] = [:],
    on tab: String? = nil, as caller: AppletCaller? = nil,
    holding powers: Set<AppletCommandPermission> = [.browserNavigation, .browserRead]
  ) -> Result<JSONValue, AppletCommandError> {
    var result: Result<JSONValue, AppletCommandError>?
    let identity = caller ?? grant

    dispatcher.submit(
      AppletCommandSubmission(
        appletType: BrowserApplet.descriptionTypeID, schemaVersion: AppletSchemaVersion(1, 0),
        name: name, arguments: .object(arguments)),
      to: harness.applet, authority: { nil },
      caller: { CommandCaller(identity: identity, permissions: powers) },
      tab: tab.flatMap(AppletTabID.init(reply:)), reply: { result = $0 })

    let bodies = turns
    turns = []
    for body in bodies { body() }

    return result ?? .failure(AppletCommandError(.failed, "no reply"))
  }

  private func url(_ harness: BrowserHarness, _ path: String) -> JSONValue {
    .string(harness.server.url(path).absoluteString)
  }

  /// Opens a tab and returns its reference and the tab.
  private func open(_ harness: BrowserHarness, _ path: String, as caller: AppletCaller? = nil)
    throws -> (reference: String, tab: BrowserTab)
  {
    let reply = try send(harness, "open", ["url": url(harness, path)], as: caller).get()

    guard case .object(let fields) = reply, case .string(let reference)? = fields["tab"],
      let id = AppletTabID(reply: reference),
      let tab = harness.applet.tabs.first(where: { $0.id == id })
    else {
      XCTFail("open answered \(reply)")
      throw AppletCommandError(.failed, "open answered no tab")
    }

    return (reference, tab)
  }

  private func code(_ result: Result<JSONValue, AppletCommandError>) -> AppletCommandError.Code? {
    if case .failure(let error) = result { return error.code }

    return nil
  }

  // MARK: Opening

  /// Catches an open that waits to be selected, or that does not load a tab nobody looks at. In a
  /// pane without the keyboard the tab opens selected. Either way it loads at once and the reply
  /// names it.
  func testOpenLoadsTheTabAtOnceAndAnswersItsReference() async throws {
    let harness = try await make()
    defer { harness.stop() }

    let (reference, opened) = try open(harness, "/a")

    XCTAssertEqual(harness.applet.tabs.count, 2)
    XCTAssertEqual(harness.applet.tab, opened, "no keyboard in the pane, so the tab shows")
    XCTAssertEqual(opened.id.replyText, reference)

    await harness.host.until("the page loads") { opened.pageTitle == "A" }

    XCTAssertEqual(harness.count("GET", "/a"), 1)
  }

  /// Catches an open that moves the keyboard: in a key-focused pane the tab opens unselected,
  /// the user's tab keeps the keyboard, and the new tab loads in the background.
  func testOpenInAKeyFocusedPaneLeavesTheUsersTabSelectedAndLoadsInTheBackground() async throws {
    let harness = try await make(hosting: .focusedWindow)
    defer { harness.stop() }

    let users = harness.applet.tab
    let (_, opened) = try open(harness, "/a")

    XCTAssertTrue(harness.applet.tab === users)
    XCTAssertNotEqual(harness.applet.tab, opened)
    XCTAssertTrue(harness.applet.hasFocus, "the keyboard is still in the page")

    await harness.host.until("the background tab loads") { opened.pageTitle == "A" }
  }

  /// Catches an open that takes the keyboard to the address bar, as the user's New Tab does.
  func testOpenNeverMovesTheKeyboardIntoTheAddressBar() async throws {
    let harness = try await make()
    defer { harness.stop() }

    let before = harness.window?.firstResponder

    _ = try open(harness, "/a")

    XCTAssertTrue(harness.window?.firstResponder === before)
  }

  /// Catches an address the rule refuses that opens a tab or loads: script, data, and local file
  /// addresses in any letter case and with whitespace, on open and on navigate.
  func testScriptDataAndFileAddressesAreRefusedInAnyCaseWithWhitespace() async throws {
    let harness = try await make()
    defer { harness.stop() }

    let (reference, _) = try open(harness, "/a")
    let count = harness.applet.tabs.count

    for bad in [
      "javascript:alert(1)", " JaVaScRiPt:alert(1) ", "\tJAVASCRIPT:void(0)\n",
      "data:text/html,<b>x</b>", "  DaTa:text/html,x  ", "file:///etc/hosts",
      " FILE:///etc/hosts\n",
      "\u{A0}file:///etc/hosts", "mailto:someone@example.com", "ftp://example.com/",
    ] {
      let opened = send(harness, "open", ["url": .string(bad)])
      let moved = send(harness, "navigate", ["url": .string(bad)], on: reference)

      XCTAssertEqual(code(opened), .badArgument, bad)
      XCTAssertEqual(code(moved), .badArgument, bad)
    }

    XCTAssertEqual(harness.applet.tabs.count, count, "a refused address opened a tab")
  }

  /// Catches a scheme-less address that loads over plain HTTP, or one that is refused.
  func testASchemelessAddressGetsHTTPSAndLoopbackGetsHTTP() async throws {
    let harness = try await make()
    defer { harness.stop() }

    let loopback = try open(harness, "/a")

    XCTAssertEqual(loopback.tab.record.url?.hasPrefix("http://127.0.0.1"), true)

    let reply = try send(harness, "open", ["url": .string("example.com/x")]).get()

    guard case .object(let fields) = reply, case .string(let text)? = fields["tab"],
      let id = AppletTabID(reply: text),
      let tab = harness.applet.tabs.first(where: { $0.id == id })
    else { return XCTFail("open answered \(reply)") }

    XCTAssertEqual(tab.record.url, "https://example.com/x")
  }

  /// Catches a loop of opens that builds a web view and a content process for each call. A grant
  /// holds at most 16 tabs, the 17th is refused as busy before any effect, another grant is not
  /// held to the first one's count, and a tab the user closes frees a place.
  func testAGrantMayHoldOnlyAFixedNumberOfTabs() async throws {
    let harness = try await make()
    defer { harness.stop() }

    var last = ""

    for _ in 0..<BrowserApplet.controllerTabLimit { last = try open(harness, "/a").reference }

    let count = harness.applet.tabCount
    let served = harness.server.requests.count
    let refused = send(harness, "open", ["url": url(harness, "/b")])

    XCTAssertEqual(code(refused), .busy)
    XCTAssertEqual(harness.applet.tabCount, count, "a refused open built a tab")
    XCTAssertEqual(harness.count("GET", "/b"), 0)
    XCTAssertGreaterThanOrEqual(harness.server.requests.count, served)

    XCTAssertNil(code(send(harness, "open", ["url": url(harness, "/c")], as: other)))

    let closing = try XCTUnwrap(harness.applet.tabs.firstIndex { $0.id.replyText == last })

    _ = await harness.applet.closeTab(at: closing)

    XCTAssertNil(code(send(harness, "open", ["url": url(harness, "/d")])))
  }

  // MARK: Ownership

  /// Catches a command that acts on a tab its caller did not open: the user's own tab, and a tab
  /// another grant opened.
  func testACommandOnATabTheCallerDidNotOpenIsRefused() async throws {
    let harness = try await make()
    defer { harness.stop() }

    let users = harness.applet.tab.id.replyText
    let (mine, _) = try open(harness, "/a")

    for name in ["reload", "back", "forward", "select", "read"] {
      XCTAssertEqual(code(send(harness, name, on: users)), .notOwned, name)
      XCTAssertEqual(code(send(harness, name, on: mine, as: other)), .notOwned, name)
    }

    XCTAssertEqual(
      code(send(harness, "navigate", ["url": url(harness, "/b")], on: users)), .notOwned)
    XCTAssertEqual(harness.count("GET", "/b"), 0)
  }

  /// Catches a tab that stops being the controller's once the user types in it. The controller
  /// still reads it, and a move is refused for the input and not for ownership.
  func testATabStaysTheControllersAfterTheUserTypesInIt() async throws {
    let harness = try await make()
    defer { harness.stop() }

    let (reference, opened) = try open(harness, "/draft")

    await harness.host.until("the draft page shows") { opened.pageTitle == "Draft" }

    await harness.host.until("input is marked") {
      Task { @MainActor in
        _ = try? await opened.webView.evaluateJavaScript(
          "var e = document.getElementById('a'); e.focus(); e.select()")
        (opened.webView as? any NSTextInputClient)?.insertText(
          "typed", replacementRange: NSRange(location: NSNotFound, length: 0))
      }

      return opened.hasUnsentInput
    }

    XCTAssertTrue(opened.hasUnsentInput)

    harness.applet.selectTab(at: 0, takingKeyboard: false)

    XCTAssertNil(code(send(harness, "read", on: reference)))
    XCTAssertEqual(
      code(send(harness, "navigate", ["url": url(harness, "/b")], on: reference)),
      .unsentInput)
    XCTAssertEqual(code(send(harness, "reload", on: reference)), .unsentInput)
    XCTAssertEqual(harness.count("GET", "/b"), 0)
  }

  /// Catches a tab that is owned without the controller opening it: a tab a page opened from a
  /// controller tab, a tab reopened with Cmd-Shift-T, and a restored tab.
  func testPageOpenedReopenedAndRestoredTabsBelongToNoController() async throws {
    let harness = try await make()
    defer { harness.stop() }

    let (reference, opened) = try open(harness, "/a")

    await harness.host.until("the page loads") { opened.pageTitle == "A" }

    _ = try? await opened.webView.evaluateJavaScript("window.open('/popup')")
    await harness.host.until("the popup opens") { harness.applet.tabs.count == 3 }

    let popup = try XCTUnwrap(harness.applet.tabs.first { $0.isPopup })

    XCTAssertNil(harness.applet.tabOwners[popup.id], "a page-opened tab was owned")
    XCTAssertFalse(popup.isControlled)

    let closing = harness.applet.tabs.firstIndex { $0 === opened }!
    _ = await harness.applet.closeTab(at: closing)

    let stamp = try XCTUnwrap(harness.applet.closedTabStamps.first)

    XCTAssertEqual(harness.applet.reopenTab(stamp: stamp), .reopened(title: "A"))
    XCTAssertEqual(harness.applet.tabOwners.count, 0, "a reopened tab was owned")
    XCTAssertEqual(code(send(harness, "read", on: reference)), .notFound)

    let restored = try BrowserApplet(
      restoring: harness.applet.describe(), dataStore: .nonPersistent(),
      services: .testing())

    XCTAssertEqual(restored.tabOwners.count, 0)
    XCTAssertTrue(restored.tabs.allSatisfy { !$0.isControlled })
    restored.close()
  }

  /// Catches ownership that outlives its grant: a new generation of control, a grant that ended,
  /// and a closed tab each leave nothing owned.
  func testOwnershipEndsWithTheGrantTheGenerationAndTheTab() async throws {
    let harness = try await make()
    defer { harness.stop() }

    let (first, _) = try open(harness, "/a")

    harness.applet.controlDidChange(
      PaneControl(access: .remoteControlled, driver: .none, generation: 4))

    XCTAssertEqual(code(send(harness, "read", on: first)), .notOwned)

    let (second, secondTab) = try open(harness, "/c")

    harness.applet.controlDidChange(
      PaneControl(access: .remoteControlled, driver: .none, generation: 4))

    XCTAssertNil(code(send(harness, "read", on: second)), "the same generation changes nothing")

    harness.applet.grantDidEnd(other)

    XCTAssertNil(code(send(harness, "read", on: second)), "another grant's end changes nothing")

    harness.applet.grantDidEnd(grant)

    XCTAssertEqual(code(send(harness, "read", on: second)), .notOwned)
    XCTAssertFalse(secondTab.isControlled)

    let (third, _) = try open(harness, "/b")
    let closing = try XCTUnwrap(harness.applet.tabs.firstIndex { $0.id.replyText == third })

    _ = await harness.applet.closeTab(at: closing)

    XCTAssertEqual(code(send(harness, "read", on: third)), .notFound)
    XCTAssertEqual(harness.applet.tabOwners.count, 0)
  }

  /// Catches a pane a layout created whose first tab is not its controller's, and one that keeps
  /// it for the wrong grant.
  func testTheFirstTabOfALayoutPaneBelongsToTheLayoutsCaller() async throws {
    let harness = try await make()
    defer { harness.stop() }

    harness.applet.adoptFirstTab(for: grant)

    let first = harness.applet.tab.id.replyText

    XCTAssertNil(code(send(harness, "read", on: first)))
    XCTAssertEqual(code(send(harness, "read", on: first, as: other)), .notOwned)
  }

  // MARK: Powers

  /// Catches a browser power that unlocks the other's commands, and a command that runs without
  /// its power.
  func testEachBrowserPowerUnlocksOnlyItsOwnCommands() async throws {
    let harness = try await make()
    defer { harness.stop() }

    let (reference, _) = try open(harness, "/a")

    XCTAssertEqual(
      code(send(harness, "open", ["url": url(harness, "/x")], holding: [.browserRead])),
      .permissionMissing)
    XCTAssertEqual(
      code(send(harness, "read", on: reference, holding: [.browserNavigation])),
      .permissionMissing)
    XCTAssertEqual(code(send(harness, "reload", on: reference, holding: [])), .permissionMissing)
    XCTAssertEqual(harness.count("GET", "/x"), 0)
    XCTAssertEqual(harness.applet.tabs.count, 2)
  }

  // MARK: Moves

  /// Catches a navigate, reload, back, or forward that does not act on the controller's tab, and
  /// a reply that does not carry what the page shows.
  func testNavigateReloadBackAndForwardMoveTheControllersTab() async throws {
    let harness = try await make()
    defer { harness.stop() }

    let (reference, opened) = try open(harness, "/a")

    await harness.host.until("a loads") { opened.pageTitle == "A" }

    XCTAssertNil(code(send(harness, "navigate", ["url": url(harness, "/b")], on: reference)))
    await harness.host.until("b loads") { opened.pageTitle == "B" && !opened.isLoading }

    XCTAssertNil(code(send(harness, "back", on: reference)))
    await harness.host.until("back shows a") { opened.pageTitle == "A" && !opened.isLoading }

    XCTAssertNil(code(send(harness, "forward", on: reference)))
    await harness.host.until("forward shows b") { opened.pageTitle == "B" && !opened.isLoading }

    let served = harness.count("GET", "/b")

    XCTAssertNil(code(send(harness, "reload", on: reference)))
    await harness.eventually("the reload asks the server again") {
      harness.count("GET", "/b") == served + 1
    }

    guard case .success(.object(let read)) = send(harness, "read", on: reference) else {
      return XCTFail("read failed")
    }

    XCTAssertEqual(read["title"], .string("B"))
    XCTAssertEqual(read["url"], url(harness, "/b"))
  }

  /// Catches a back or forward with nowhere to go that answers as if it moved.
  func testHistoryWithNowhereToGoIsAFailureNotAMove() async throws {
    let harness = try await make()
    defer { harness.stop() }

    let (reference, opened) = try open(harness, "/a")

    await harness.host.until("a loads") { opened.pageTitle == "A" }

    XCTAssertEqual(code(send(harness, "back", on: reference)), .failed)
    XCTAssertEqual(code(send(harness, "forward", on: reference)), .failed)
  }

  /// Catches a move on the tab the user is looking at in a pane that holds the keyboard, and a
  /// select that takes the user's tab away. A background tab still moves.
  func testAKeyFocusedPaneRefusesMovesOnItsShownTabAndRefusesSelect() async throws {
    let harness = try await make(hosting: .focusedWindow)
    defer { harness.stop() }

    harness.applet.adoptFirstTab(for: grant)

    let shown = harness.applet.tab.id.replyText
    let (background, tab) = try open(harness, "/a")

    for name in ["reload", "back", "forward"] {
      XCTAssertEqual(code(send(harness, name, on: shown)), .keyFocused, name)
    }

    XCTAssertEqual(
      code(send(harness, "navigate", ["url": url(harness, "/b")], on: shown)), .keyFocused)
    XCTAssertEqual(code(send(harness, "select", on: background)), .keyFocused)
    XCTAssertEqual(harness.count("GET", "/b"), 0)
    XCTAssertFalse(harness.applet.tab === tab)

    XCTAssertNil(code(send(harness, "navigate", ["url": url(harness, "/b")], on: background)))
    await harness.host.until("the background tab moves") { tab.pageTitle == "B" }
  }

  /// Catches a select that moves the keyboard, or one that refuses when nobody holds it.
  func testSelectShowsTheTabWithoutMovingTheKeyboard() async throws {
    let harness = try await make()
    defer { harness.stop() }

    let users = harness.applet.tab
    let (reference, opened) = try open(harness, "/a")

    harness.applet.selectTab(at: 0, takingKeyboard: false)
    XCTAssertTrue(harness.applet.tab === users)

    let before = harness.window?.firstResponder

    XCTAssertNil(code(send(harness, "select", on: reference)))
    XCTAssertTrue(harness.applet.tab === opened)
    XCTAssertTrue(harness.window?.firstResponder === before)
  }

  // MARK: Forms

  /// Catches a controller's reload, back, or forward that sends a form again, and one that asks
  /// the user. The same move from the tab's own button asks, which is the contrast.
  func testAControllersReloadNeverResendsAFormAndNeverAsks() async throws {
    let harness = try await make()
    defer { harness.stop() }

    harness.host.recording.answer = true

    let (reference, opened) = try open(harness, "/form")

    await harness.host.until("the form shows") { opened.pageTitle == "Form" && !opened.isLoading }
    _ = try? await opened.webView.evaluateJavaScript("document.forms[0].submit()")
    await harness.host.until("the post result shows") {
      opened.pageTitle == "Posted" && !opened.isLoading
    }

    XCTAssertEqual(harness.count("POST", "/result"), 1)

    XCTAssertNil(code(send(harness, "reload", on: reference)))
    await harness.host.until("the refusal is reported") { !harness.posts.isEmpty }

    XCTAssertTrue(harness.posts.last?.text.contains("send the form again") ?? false)
    XCTAssertTrue(harness.host.recording.confirmations.isEmpty, "a controller's reload asked")
    XCTAssertEqual(harness.count("POST", "/result"), 1)

    XCTAssertEqual(opened.reload(), .moved)
    await harness.host.until("the tab's own reload asks") {
      harness.host.recording.confirmations.count == 1
    }
  }

  // MARK: Questions

  /// Catches a link to another app in a controller tab that opens at once, `mailto:` included, and
  /// a user's own tab that stopped opening it at once.
  func testEveryAppHandoffFromAControllerTabAsksFirst() async throws {
    let opener = FakeOpener()
    let harness = try await make(services: .testing(opener: opener))
    defer { harness.stop() }

    let mail = URL(string: "mailto:someone@example.com")!

    harness.applet.tab(harness.applet.tab, handOff: mail)
    XCTAssertEqual(opener.opened, [mail], "the user's own tab opens a draft at once")

    let (_, owned) = try open(harness, "/a")

    harness.host.recording.answer = false
    harness.applet.tab(owned, handOff: mail)
    await harness.host.until("the question is asked") {
      harness.host.recording.confirmations.count == 1
    }

    XCTAssertEqual(opener.opened, [mail], "a controller's tab opened a draft without asking")
  }

  /// Catches a download in a controller tab that starts without the user's yes, and one that
  /// counts against the free three. The user's own tab starts the same download at once.
  func testADownloadInAControllerTabWaitsForTheUsersAnswer() async throws {
    let harness = try await BrowserHarness.make(handler: Self.pages)
    defer { harness.stop() }

    let (reference, owned) = try open(harness, "/a")

    await harness.host.until("a loads") { owned.pageTitle == "A" }

    harness.host.recording.answer = false

    XCTAssertNil(code(send(harness, "navigate", ["url": url(harness, "/file")], on: reference)))
    await harness.host.until("the question is asked") {
      harness.host.recording.confirmations.count == 1
    }

    XCTAssertEqual(harness.files(), [])
    XCTAssertEqual(harness.applet.downloads.runningNames, [])
  }

  // MARK: Attachment

  /// Catches a tab opened while the pane was detached that never loads, or one that loads in the
  /// meantime.
  func testATabOpenedWhileDetachedLoadsWhenThePaneComesBack() async throws {
    let harness = try await make()
    defer { harness.stop() }

    harness.applet.detach()

    let (_, opened) = try open(harness, "/a")

    XCTAssertEqual(harness.count("GET", "/a"), 0, "a detached pane loaded a page")

    harness.applet.reattach()
    await harness.host.until("the tab loads") { opened.pageTitle == "A" }

    XCTAssertEqual(harness.count("GET", "/a"), 1)
  }

  // MARK: Seeds and programs

  /// Catches a seeded pane that loads nothing, or an unseeded one that requests a page.
  func testASeededPaneLoadsItsPageAtStartAndAnUnseededOneLoadsNothing() async throws {
    let server = try await FixtureServer.start(handler: Self.pages)
    defer { server.stop() }

    let seeded = BrowserApplet(
      dataStore: .nonPersistent(), services: .testing(), seed: server.url("/seed"))
    let host = EventHost()

    seeded.host = host
    seeded.start(origin: .user)
    await host.until("the seed loads") { seeded.title == "SEED" }
    seeded.close()

    let blank = BrowserApplet(dataStore: .nonPersistent(), services: .testing())

    blank.start(origin: .user)
    XCTAssertNil(blank.tab.record.url)
    blank.close()

    XCTAssertEqual(server.requests.filter { $0.path == "/seed" }.count, 1)
  }

  /// Catches a generic tab open from a program that reaches the browser, and a user's New Tab that
  /// the program rule blocks.
  func testAProgramMayNotOpenATabThroughTheGenericOpen() async throws {
    let harness = try await make()
    defer { harness.stop() }

    let refusal = try XCTUnwrap(harness.applet.programOpenRefusal)

    XCTAssertTrue(refusal.contains("open"), refusal)
    XCTAssertTrue(refusal.contains("browser-navigation"), refusal)
    XCTAssertNotNil(harness.applet.openTab(startingIn: nil), "the user's New Tab still works")
  }

  /// Catches a browser that takes an exec driver, or loses remote control.
  func testTheBrowserSupportsRemoteControlAndNoExecDriver() {
    XCTAssertEqual(
      BrowserApplet.typeDeclaration.controlSupport,
      [.disconnected, .remoteControlled])
    XCTAssertFalse(
      BrowserApplet.typeDeclaration.controlSupport.contains(
        ControlCombination(access: .remoteControlled, driver: .exec)))
    XCTAssertFalse(
      BrowserApplet.typeDeclaration.controlSupport.contains(
        ControlCombination(access: .disconnected, driver: .exec)))
  }

  /// Catches a command with no summary, an example that its own schema refuses, or a command that
  /// names no power. The schema is what a driver author reads.
  func testEveryCommandIsDescribedAndItsExampleFitsItsSchema() throws {
    let schema = BrowserApplet.remoteSchema

    XCTAssertEqual(
      schema.commands.map(\.name),
      ["open", "navigate", "reload", "back", "forward", "select", "read"])

    for command in schema.commands {
      XCTAssertFalse(command.summary.isEmpty, command.name)
      XCTAssertNotNil(command.permission, command.name)
      XCTAssertEqual(command.permission == .browserRead, command.name == "read", command.name)
      XCTAssertFalse(command.mayWait, command.name)

      guard case .object(let fields) = command.example else {
        return XCTFail("\(command.name) has no example object")
      }

      XCTAssertNoThrow(try command.arguments.validate(fields, at: command.name), command.name)
    }
  }
}
