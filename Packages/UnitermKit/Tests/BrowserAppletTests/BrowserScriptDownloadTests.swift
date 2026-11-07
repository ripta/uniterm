import BrowserTestSupport
import StatusKit
import WebKit
import XCTest

@testable import BrowserApplet

/// The bookkeeping of a page's downloads that no click started.
final class DownloadHoldTests: XCTestCase {
  /// Catches a free limit that is off by one, or a hold that grows without end. Three downloads
  /// start free and the fourth does not. Decisions past the held bound are refused.
  func testThreeStartFreeAndTheHeldListIsBounded() {
    var hold = DownloadHold()

    XCTAssertTrue(hold.countStart())
    XCTAssertTrue(hold.countStart())
    XCTAssertTrue(hold.countStart())
    XCTAssertFalse(hold.countStart())

    for _ in 0..<DownloadHold.heldLimit {
      XCTAssertTrue(hold.hold(DownloadHold.Held(name: nil, resolve: { _ in })))
    }

    XCTAssertFalse(hold.hold(DownloadHold.Held(name: nil, resolve: { _ in })))
  }

  /// Catches a load that keeps the old page's count. A reset forgets everything and moves the
  /// epoch.
  func testAResetStartsTheCountOver() {
    var hold = DownloadHold()
    let before = hold.epoch

    _ = hold.countStart()
    hold.setPhase(.refused)
    hold.reset()

    XCTAssertEqual(hold.phase, .counting)
    XCTAssertEqual(hold.started, 0)
    XCTAssertNotEqual(hold.epoch, before)
  }
}

/// How the tab follows the navigation a click of the user's started.
final class UserNavigationTests: XCTestCase {
  /// Catches a mark that outlives its navigation. A click that is never confirmed by a provisional
  /// start ends at the next action decision, and a confirmed navigation ends at its response.
  func testTheMarkCoversOnlyTheNavigationTheClickStarted() {
    var navigation = UserNavigation()

    XCTAssertTrue(
      navigation.decideAction(followedByUser: true, isMainFrame: true, isRedirectLike: false))
    XCTAssertFalse(
      navigation.decideAction(followedByUser: false, isMainFrame: true, isRedirectLike: true),
      "an unconfirmed click passed a script's navigation as the user's")
    XCTAssertEqual(navigation.state, .none)

    XCTAssertTrue(
      navigation.decideAction(followedByUser: true, isMainFrame: true, isRedirectLike: false))
    navigation.started()

    XCTAssertTrue(
      navigation.decideAction(followedByUser: false, isMainFrame: true, isRedirectLike: true),
      "a redirect of the user's navigation is the user's")
    XCTAssertFalse(
      navigation.decideAction(followedByUser: false, isMainFrame: false, isRedirectLike: true),
      "a subframe inherited the mark")

    XCTAssertTrue(
      navigation.decideAction(followedByUser: true, isMainFrame: true, isRedirectLike: false))
    navigation.started()

    XCTAssertTrue(navigation.response(isMainFrame: true))
    XCTAssertEqual(navigation.state, .none)
    XCTAssertFalse(navigation.response(isMainFrame: true))
  }

  /// Catches a typed address that loses its mark, and a typed mark that a script can take. The
  /// first main-frame decision after a typed load is its own.
  func testATypedLoadIsTheUsersUntilItsResponse() {
    var navigation = UserNavigation()

    navigation.typedLoad()

    XCTAssertTrue(
      navigation.decideAction(followedByUser: false, isMainFrame: true, isRedirectLike: true))
    navigation.started()

    XCTAssertTrue(navigation.response(isMainFrame: true))
  }
}

/// A page whose script starts downloads with no click of the user's. Each test runs real
/// downloads against the fixture server and a Downloads folder the harness removes. A file in
/// that folder is the proof that a download started.
@MainActor
final class BrowserScriptDownloadTests: XCTestCase {
  private nonisolated static let handler: FixtureServer.Handler = { request in
    if request.path.hasPrefix("/f/") {
      let name = request.path.dropFirst(3)

      return FixtureServer.Response(
        status: 200,
        headers: [
          ("Content-Type", "application/octet-stream"),
          ("Content-Disposition", "attachment; filename=\"f\(name).txt\""),
        ], body: Data("x".utf8))
    }

    return Pages.page(
      String(request.path.dropFirst()).uppercased(),
      "<a id=l href=/f/user>get</a><a id=anchor href=#here>here</a>")
  }

  private func make() async throws -> BrowserHarness {
    let harness = try await BrowserHarness.make(hosting: .window, handler: Self.handler)

    harness.host.recording.holdsQuestions = true

    await harness.load("/page", expecting: "PAGE")

    return harness
  }

  /// A script clicks a link to `/f/<name>`. WebKit sees a followed link with no mouse-up.
  private func scriptDownload(_ name: String, _ harness: BrowserHarness) async {
    await harness.run(
      """
      var a = document.createElement('a');
      a.href = '/f/\(name)';
      document.body.appendChild(a);
      a.click();
      void 0
      """)
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

  private func startFree(_ harness: BrowserHarness, prefix: String = "") async {
    for index in 0..<DownloadHold.freeLimit {
      await scriptDownload("\(prefix)\(index)", harness)
      await harness.eventually("download \(prefix)\(index) lands") {
        harness.files().contains("f\(prefix)\(index).txt")
      }
    }
  }

  /// Catches a page that starts as many downloads as it likes. The first three start as before.
  /// The fourth holds its decision, and the pane asks once, naming the page and the file. No file
  /// of the fourth exists while the question is up, and a yes starts it. The page can then
  /// download freely with no further question.
  func testTheFourthScriptDownloadAsksAndYesStartsItAndLiftsTheLimit() async throws {
    let harness = try await make()
    defer { harness.stop() }

    await startFree(harness)

    XCTAssertTrue(harness.host.recording.confirmations.isEmpty)

    await scriptDownload("3", harness)
    await waitForQuestion(harness)

    let request = try XCTUnwrap(harness.host.recording.confirmations.first)

    XCTAssertTrue(request.detail.contains("PAGE"), request.detail)
    XCTAssertTrue(request.detail.contains("f3.txt"), request.detail)
    XCTAssertEqual(harness.files(), ["f0.txt", "f1.txt", "f2.txt"], "a file exists before the yes")

    answer(true, harness)

    await harness.eventually("the fourth lands") { harness.files().contains("f3.txt") }

    await scriptDownload("4", harness)
    await harness.eventually("the fifth lands") { harness.files().contains("f4.txt") }

    XCTAssertEqual(harness.host.recording.confirmations.count, 1)
  }

  /// Catches a no that starts the file anyway, warns twice, or asks again. A no cancels the
  /// download at the decision, posts one warning, and refuses the page's further downloads with no
  /// further question, until the page loads again.
  func testNoCancelsTheDownloadWarnsOnceAndHoldsUntilTheNextLoad() async throws {
    let harness = try await make()
    defer { harness.stop() }

    await startFree(harness)
    harness.host.recording.forgetSent()
    await scriptDownload("3", harness)
    await waitForQuestion(harness)
    answer(false, harness)

    await harness.host.until("the warning is heard") { self.warnings(harness).count == 1 }

    await scriptDownload("4", harness)
    await scriptDownload("5", harness)

    for _ in 0..<200 { await Task.yield() }

    XCTAssertEqual(harness.files(), ["f0.txt", "f1.txt", "f2.txt"])
    XCTAssertEqual(harness.host.recording.confirmations.count, 1)
    XCTAssertEqual(warnings(harness).count, 1)

    await harness.load("/page2", expecting: "PAGE2")
    await startFree(harness, prefix: "n")
    await scriptDownload("n3", harness)
    await waitForQuestion(harness, 2)

    answer(false, harness)
  }

  /// Catches a click of the user's own that counts or asks. A real click on a link starts any
  /// number of downloads and never asks.
  func testRealClicksNeverCountAndNeverAsk() async throws {
    let harness = try await make()
    defer { harness.stop() }

    for index in 1...(DownloadHold.freeLimit + 3) {
      harness.tab.noteMouseUp()
      await harness.run("document.getElementById('l').click()")
      await harness.host.until("click \(index) lands") { harness.files().count == index }
    }

    XCTAssertTrue(harness.host.recording.confirmations.isEmpty)
  }

  /// Catches a click that leaves the user's mark behind. A real click on a `#fragment` link starts
  /// no main-frame navigation, so nothing ends the mark by a response. A script that then sets
  /// `location` to a file is not the user's, so its downloads count and the fourth asks.
  func testARealClickThatStartsNoNavigationDoesNotMakeLaterScriptDownloadsTheUsers() async throws {
    let harness = try await make()
    defer { harness.stop() }

    harness.tab.noteMouseUp()
    await harness.run("document.getElementById('anchor').click(); void 0")

    for index in 0..<DownloadHold.freeLimit {
      await harness.run("location = '/f/s\(index)'")
      await harness.eventually("download s\(index) lands") {
        harness.files().contains("fs\(index).txt")
      }
    }

    XCTAssertTrue(harness.host.recording.confirmations.isEmpty)

    await harness.run("location = '/f/s3'")
    await waitForQuestion(harness)

    XCTAssertFalse(harness.files().contains("fs3.txt"), "the fourth started without a yes")

    answer(false, harness)
  }

  /// Catches a decision handler left behind. Closing the pane while the question is up resolves
  /// the held decision as cancelled, so no file appears after a late yes.
  func testClosingThePaneResolvesTheHeldDecision() async throws {
    let harness = try await make()
    defer { harness.stop() }

    await startFree(harness)
    await scriptDownload("3", harness)
    await waitForQuestion(harness)

    let page = harness.tab

    XCTAssertEqual(page.downloadHold.held.count, 1)

    harness.applet.close()

    XCTAssertTrue(page.downloadHold.held.isEmpty, "the held decision outlived its pane")

    answer(true, harness)

    for _ in 0..<200 { await Task.yield() }

    XCTAssertFalse(harness.files().contains("f3.txt"))
  }

  /// Catches a lost decision when another question is up. Page B passes the limit while the
  /// question about page A is up. Its decision is held, nothing stacks, and the pane asks about B
  /// once A is answered. B's yes starts its download.
  func testADownloadThatFindsAnotherQuestionUpAsksOnceThePaneIsFree() async throws {
    let harness = try await make()
    defer { harness.stop() }

    await startFree(harness)
    await scriptDownload("3", harness)
    await waitForQuestion(harness)

    harness.applet.openTab()
    await harness.load("/other", expecting: "OTHER")
    await startFree(harness, prefix: "b")
    await scriptDownload("b3", harness)

    for _ in 0..<200 { await Task.yield() }

    XCTAssertEqual(harness.host.recording.confirmations.count, 1, "a second question stacked")

    answer(false, harness)
    await waitForQuestion(harness, 2)

    XCTAssertTrue(
      harness.host.recording.confirmations[1].detail.contains("OTHER"),
      harness.host.recording.confirmations[1].detail)
    XCTAssertFalse(harness.files().contains("fb3.txt"))

    answer(true, harness)

    await harness.eventually("page B's download lands") { harness.files().contains("fb3.txt") }

    XCTAssertFalse(harness.files().contains("f3.txt"), "page A's refused download landed")
  }
}
