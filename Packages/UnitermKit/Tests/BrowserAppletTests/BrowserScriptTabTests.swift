import BrowserTestSupport
import StatusKit
import WebKit
import XCTest

@testable import BrowserApplet

/// The remembered addresses of a page that passed the limit on script-opened tabs.
final class ScriptTabHoldTests: XCTestCase {
  /// Catches a list that grows without end, or a count that hides what was dropped. Addresses
  /// past the limit and calls with no address are counted and not kept, so a message can say how
  /// many the page tried.
  func testTheListKeepsTheLimitAndCountsTheRest() throws {
    var hold = ScriptTabHold()

    for index in 0..<(ScriptTabHold.addressLimit + 5) {
      hold.remember(URL(string: "https://example.test/\(index)"))
    }

    hold.remember(nil)

    XCTAssertEqual(hold.addresses.count, ScriptTabHold.addressLimit)
    XCTAssertEqual(hold.dropped, 6)
    XCTAssertEqual(hold.attempts, ScriptTabHold.addressLimit + 6)
    XCTAssertEqual(hold.addresses.first?.path, "/0")
  }

  /// Catches a load that leaves the old page's list and permission in place. A reset forgets
  /// everything and moves the epoch, so an answer to an earlier question is told apart.
  func testAResetForgetsTheListAndChangesTheEpoch() {
    var hold = ScriptTabHold()
    let before = hold.epoch

    hold.remember(URL(string: "https://example.test/a"))
    hold.setPhase(.refused)
    hold.reset()

    XCTAssertEqual(hold.phase, .counting)
    XCTAssertTrue(hold.addresses.isEmpty)
    XCTAssertEqual(hold.attempts, 0)
    XCTAssertNotEqual(hold.epoch, before)
  }
}

/// A page whose script opens tabs past the pane's limit. Each test runs a real loop of
/// `window.open` calls through `evaluateJavaScript`, which WebKit counts as a gesture, against a
/// real web view served by the fixture server.
@MainActor
final class BrowserScriptTabTests: XCTestCase {
  private nonisolated static let handler: FixtureServer.Handler = { request in
    Pages.page(String(request.path.dropFirst()).uppercased())
  }

  private func make() async throws -> BrowserHarness {
    let harness = try await BrowserHarness.make(hosting: .window, handler: Self.handler)

    harness.host.recording.holdsQuestions = true

    await harness.load("/page", expecting: "PAGE")

    return harness
  }

  /// Calls `window.open` for `count` distinct addresses under `prefix`, and returns how many
  /// returned a window.
  @discardableResult
  private func open(
    _ count: Int, prefix: String = "/p", in tab: BrowserTab, _ harness: BrowserHarness
  ) async throws -> Int {
    let script = """
      var opened = 0;
      for (var i = 0; i < \(count); i++) { if (window.open('\(prefix)/' + i)) { opened += 1; } }
      opened
      """

    return try await tab.webView.evaluateJavaScript(script) as? Int ?? -1
  }

  private func waitForQuestion(_ harness: BrowserHarness, _ count: Int = 1) async {
    await harness.host.until("question \(count) is asked") {
      harness.host.recording.confirmations.count >= count
    }
  }

  private func answer(_ yes: Bool, _ harness: BrowserHarness) {
    harness.host.recording.pendingAnswer?.resume(returning: yes)
    harness.host.recording.pendingAnswer = nil
  }

  private func warnings(_ harness: BrowserHarness) -> [String] {
    harness.posts.filter { $0.level == .warning }.map(\.text)
  }

  /// Catches a script loop that opens everything, or a pane that decides for the user. A loop of 15
  /// opens 10 tabs and the pane asks once, naming the page and the count it holds. The other 5
  /// addresses stay unopened while the question is up, and a yes opens all of them as ordinary
  /// unselected tabs with no opener, in order.
  func testALoopOfFifteenOpensTenAsksOnceAndYesOpensTheRestInOrder() async throws {
    let harness = try await make()
    defer { harness.stop() }

    let page = harness.tab

    let opened = try await open(15, in: page, harness)

    XCTAssertEqual(opened, BrowserApplet.popupLimit)

    await waitForQuestion(harness)

    let request = try XCTUnwrap(harness.host.recording.confirmations.first)

    XCTAssertEqual(harness.host.recording.confirmations.count, 1)
    XCTAssertTrue(request.detail.contains("PAGE"), request.detail)
    XCTAssertTrue(request.detail.contains("\(BrowserApplet.popupLimit)"), request.detail)
    XCTAssertEqual(harness.applet.tabCount, 1 + BrowserApplet.popupLimit)

    for index in 10..<15 {
      XCTAssertEqual(harness.count("GET", "/p/\(index)"), 0, "tab \(index) opened before the yes")
    }

    let selected = harness.tab

    answer(true, harness)

    await harness.host.until("the rest open") { harness.applet.tabCount == 16 }

    XCTAssertTrue(harness.tab === selected, "the yes moved the selection")

    let later = harness.applet.tabs.filter { !$0.isScriptOpened && $0 !== page }

    XCTAssertEqual(later.count, 5)
    XCTAssertTrue(later.allSatisfy { !$0.isPopup && $0.opener == nil })
    XCTAssertEqual(
      later.map { $0.record.url.flatMap { URL(string: $0)?.path } }, (10..<15).map { "/p/\($0)" })

    await harness.eventually("the five load") {
      (10..<15).allSatisfy { harness.count("GET", "/p/\($0)") == 1 }
    }

    let free = try await open(3, prefix: "/q", in: page, harness)

    XCTAssertEqual(free, 3, "the page can open tabs freely after the yes")
    XCTAssertEqual(harness.host.recording.confirmations.count, 1)
  }

  /// The pane's tabs by title, left to right.
  private func order(_ harness: BrowserHarness) -> [String] {
    harness.applet.tabs.map { $0.pageTitle ?? "" }
  }

  /// Catches a loop that reads backwards. Each script-opened tab goes after the page's previous
  /// one, so a loop of 15 reads 0 to 14 left to right, the five that a yes opens included. The
  /// opener stays first, and selection stays where it was.
  func testALoopReadsInOrderLeftToRightIncludingTheTabsAYesOpens() async throws {
    let harness = try await make()
    defer { harness.stop() }

    let page = harness.tab

    try await open(15, in: page, harness)
    await waitForQuestion(harness)

    let selected = harness.tab

    answer(true, harness)

    await harness.host.until("the rest open") { harness.applet.tabCount == 16 }
    await harness.eventually("every tab has a title") {
      !harness.applet.tabs.contains { $0.pageTitle == nil }
    }

    XCTAssertEqual(order(harness), ["PAGE"] + (0..<15).map { "P/\($0)" })
    XCTAssertTrue(harness.tab === selected, "the yes moved the selection")
  }

  /// Catches a group that scatters when a tab leaves it. With the middle tab closed, the next one
  /// goes after the last that remains.
  func testAClosedTabLeavesTheRestOfTheGroupTogether() async throws {
    let harness = try await make()
    defer { harness.stop() }

    let page = harness.tab

    try await open(3, in: page, harness)
    await harness.eventually("every tab has a title") {
      harness.applet.tabCount == 4 && !harness.applet.tabs.contains { $0.pageTitle == nil }
    }

    XCTAssertEqual(order(harness), ["PAGE", "P/0", "P/1", "P/2"])

    let result = await harness.applet.closeTab(at: 2)

    XCTAssertEqual(result, .closed)

    try await open(1, prefix: "/q", in: page, harness)
    await harness.eventually("every tab has a title") {
      harness.applet.tabCount == 4 && !harness.applet.tabs.contains { $0.pageTitle == nil }
    }

    XCTAssertEqual(order(harness), ["PAGE", "P/0", "P/2", "Q/0"])
  }

  /// Catches a no that drops nothing, warns twice, or asks again. A no drops the list, posts one
  /// warning, and refuses the page's further calls with no further question. The next load of the
  /// page starts over, so its next call past the limit asks again.
  func testNoDropsTheListWarnsOnceAndHoldsUntilTheNextLoad() async throws {
    let harness = try await make()
    defer { harness.stop() }

    let page = harness.tab

    try await open(15, in: page, harness)
    await waitForQuestion(harness)
    harness.host.recording.forgetSent()
    answer(false, harness)

    await harness.host.until("the warning is heard") { self.warnings(harness).count == 1 }

    XCTAssertEqual(harness.applet.tabCount, 1 + BrowserApplet.popupLimit)

    let more = try await open(5, prefix: "/r", in: page, harness)

    XCTAssertEqual(more, 0)
    XCTAssertEqual(harness.host.recording.confirmations.count, 1, "the page was asked again")
    XCTAssertEqual(warnings(harness).count, 1)

    for index in 10..<15 {
      XCTAssertEqual(harness.count("GET", "/p/\(index)"), 0)
    }

    harness.applet.selectTab(at: 0)
    await harness.load("/page2", expecting: "PAGE2")
    try await open(2, prefix: "/s", in: page, harness)
    await waitForQuestion(harness, 2)

    XCTAssertEqual(harness.host.recording.confirmations.count, 2, "the next load did not reset")

    answer(false, harness)
  }

  /// Catches a list without a bound. A loop of 70 keeps 50 addresses. A yes opens those 50, and
  /// the message says the page tried 70.
  func testTheListIsBoundedAndTheMessageCountsWhatWasDropped() async throws {
    let harness = try await make()
    defer { harness.stop() }

    let page = harness.tab

    try await open(80, in: page, harness)
    await waitForQuestion(harness)
    harness.host.recording.forgetSent()
    answer(true, harness)

    let expected = 1 + BrowserApplet.popupLimit + ScriptTabHold.addressLimit

    await harness.host.until("the kept addresses open") { harness.applet.tabCount == expected }
    await harness.host.until("the page hears what was dropped") {
      self.warnings(harness).contains { $0.contains("70") }
    }

    XCTAssertEqual(harness.count("GET", "/p/79"), 0)
  }

  /// Catches a second page's question that is lost or stacked while the pane is busy. Page B passes
  /// the limit while the question about page A is up. Its list is kept, nothing stacks, and the
  /// pane asks about B once A is answered. B's yes opens B's addresses.
  func testAPageThatFindsAnotherQuestionUpAsksAgainOnceThePaneIsFree() async throws {
    let harness = try await make()
    defer { harness.stop() }

    let first = harness.tab

    try await open(12, in: first, harness)
    await waitForQuestion(harness)

    harness.applet.openTab()
    await harness.load("/other", expecting: "OTHER")

    let second = harness.tab

    try await open(3, prefix: "/b", in: second, harness)

    XCTAssertEqual(harness.host.recording.confirmations.count, 1, "a second question stacked")

    answer(false, harness)
    await waitForQuestion(harness, 2)

    let request = harness.host.recording.confirmations[1]

    XCTAssertTrue(request.detail.contains("OTHER"), request.detail)

    let tabs = harness.applet.tabCount

    answer(true, harness)

    await harness.host.until("page B's addresses open") { harness.applet.tabCount == tabs + 3 }

    for index in 0..<3 {
      await harness.eventually("b/\(index) loads") { harness.count("GET", "/b/\(index)") == 1 }
    }
  }

  /// Catches a late yes that opens tabs for a page that is gone. A load of the page while the
  /// question is up ends the question, and a yes afterwards opens nothing. The next call past the
  /// limit asks again.
  func testAYesAfterThePageLoadedAgainOpensNothing() async throws {
    let harness = try await make()
    defer { harness.stop() }

    let page = harness.tab

    try await open(13, in: page, harness)
    await waitForQuestion(harness)
    harness.applet.selectTab(at: 0)
    await harness.load("/page2", expecting: "PAGE2")

    let tabs = harness.applet.tabCount

    answer(true, harness)

    for _ in 0..<100 { await Task.yield() }

    XCTAssertEqual(harness.applet.tabCount, tabs)
    XCTAssertEqual(harness.count("GET", "/p/10"), 0)
  }

  /// Catches a late yes after the pane closed. Closing the pane answers no.
  func testAYesAfterThePaneClosedOpensNothing() async throws {
    let harness = try await make()
    defer { harness.stop() }

    let page = harness.tab

    try await open(13, in: page, harness)
    await waitForQuestion(harness)

    harness.applet.close()
    answer(true, harness)

    for _ in 0..<100 { await Task.yield() }

    XCTAssertEqual(harness.count("GET", "/p/10"), 0)
    XCTAssertEqual(harness.applet.tabCount, 1 + BrowserApplet.popupLimit)
  }
}
