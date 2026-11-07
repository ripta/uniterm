import Darwin
import Synchronization
import WebKit
import XCTest

@testable import BrowserApplet

/// Records every signal a test sends through `WebContentProcess`, and sends none.
private final class SignalLog: Sendable {
  private let sent = Mutex<[pid_t]>([])

  var pids: [pid_t] { sent.withLock { $0 } }

  func record(_ pid: pid_t, _: Int32) {
    sent.withLock { $0.append(pid) }
  }
}

/// The guards of the one place that signals a process. A wrong id here would end a process that
/// has nothing to do with the browser, so these tests never let a signal out.
final class WebContentProcessTests: XCTestCase {
  private func process(
    log: SignalLog, path: String? = "/x/com.apple.WebKit.WebContent.xpc/Contents/MacOS/x"
  ) -> WebContentProcess {
    WebContentProcess(pathOf: { _ in path }, signal: log.record)
  }

  /// Catches a kill that reaches the test run's own process group or a process that is not a
  /// content process. `kill(0, ...)` signals the caller's group, and 1 is launchd. The own id has
  /// a real path that is not WebKit's. Each is refused even when the path reader would say yes.
  func testIdsThatAreNotContentProcessesAreNeverSignalled() {
    let log = SignalLog()
    let guarded = process(log: log)

    XCTAssertFalse(guarded.kill(0))
    XCTAssertFalse(guarded.kill(1))
    XCTAssertFalse(guarded.kill(-1))

    let live = WebContentProcess(signal: log.record)

    XCTAssertFalse(live.kill(getpid()), "the test's own process is not a content process")
    XCTAssertTrue(log.pids.isEmpty)
  }

  /// Catches a path check that never lets a real id through, or one that lets any path through. A
  /// path reader that finds nothing, such as for an id that ended, also signals nothing.
  func testOnlyAWebKitContentProcessPathIsSignalled() {
    let log = SignalLog()

    XCTAssertTrue(process(log: log).kill(4242))
    XCTAssertFalse(process(log: log, path: "/usr/bin/true").kill(4243))
    XCTAssertFalse(process(log: log, path: nil).kill(4244))
    XCTAssertEqual(log.pids, [4242])
  }

  /// Catches a read that reports a process before the view has one. A fresh view has no content
  /// process, and its id reads as 0.
  @MainActor
  func testAViewWithNoProcessHasNoIdentifier() {
    XCTAssertNil(WebContentProcess.live.identifier(of: WKWebView()))
  }
}

/// A content process that spins. The tab ends it when its bound runs out, whether the user's
/// reload or the user's close ran into it. Each test spins a real page served by the fixture
/// server, so each proves that the process is gone and not just that a signal was sent.
@MainActor
final class BrowserHungProcessTests: XCTestCase {
  private func make(hang: HangPolicy) async throws -> BrowserHarness {
    try await BrowserHarness.make(
      services: .testing(hang: hang), hosting: .focusedWindow,
      handler: { request in Pages.page(String(request.path.dropFirst()).uppercased()) })
  }

  private func spin(_ view: WKWebView) {
    view.evaluateJavaScript("while (true) {}", completionHandler: nil)
  }

  private func policy(_ timer: ManualHangTimer, log: SignalLog? = nil) -> HangPolicy {
    var policy = timer.policy

    if let log {
      policy.process = WebContentProcess(signal: { pid, number in
        log.record(pid, number)
        _ = Darwin.kill(pid, number)
      })
    }

    return policy
  }

  private func waitUntilGone(_ pid: pid_t, in harness: BrowserHarness, _ what: String) async {
    await harness.eventually(what, seconds: 15) { !WebContent.isRunning(pid) }
  }

  /// Catches a hung process that survives its replaced view. The bound runs out, the tab builds
  /// a new view, and the old process is gone. The new view runs in a different process and shows
  /// the page. Without the kill the spinning process lives on after its view is released.
  func testTheBoundEndsTheHungProcessAndTheNewViewRunsInAnother() async throws {
    let timer = ManualHangTimer()
    let log = SignalLog()
    let harness = try await make(hang: policy(timer, log: log))
    defer { harness.stop() }

    await harness.load("/a", expecting: "A")

    let pid = try XCTUnwrap(WebContent.processID(of: harness.tab.webView))

    defer { if WebContent.isRunning(pid) { Darwin.kill(pid, SIGKILL) } }

    spin(harness.tab.webView)
    harness.applet.reload()
    timer.fire()

    await waitUntilGone(pid, in: harness, "the hung process ends")
    await harness.eventually("the page is back in a new web view") {
      harness.tab.generation == 1 && harness.tab.currentURL?.path == "/a"
        && !harness.tab.isLoading
    }

    XCTAssertEqual(log.pids, [pid])
    XCTAssertFalse(harness.tab.isStopped)

    let fresh = try XCTUnwrap(WebContent.processID(of: harness.tab.webView))

    XCTAssertNotEqual(fresh, pid)
  }

  /// Catches a kill that leaves a tab sharing the process with a wrong state. A pop-up shares its
  /// opener's process here. The opener hangs, the bound replaces it, and the pop-up hears its
  /// process end. It goes through the stopped-tab recovery, so it waits to be selected and nothing
  /// reloads by itself.
  func testATabSharingTheHungProcessRecoversAsFromAnyStoppedProcess() async throws {
    let timer = ManualHangTimer()
    let harness = try await make(hang: policy(timer))
    defer { harness.stop() }

    await harness.load("/a", expecting: "A")

    let opener = harness.tab
    let pid = try XCTUnwrap(WebContent.processID(of: opener.webView))

    defer { if WebContent.isRunning(pid) { Darwin.kill(pid, SIGKILL) } }

    await harness.run("window.open('/popup')")
    await harness.host.until("the pop-up opens") {
      harness.applet.tabCount == 2 && harness.applet.title == "POPUP"
    }

    let popup = harness.tab

    XCTAssertEqual(
      WebContent.processID(of: popup.webView), pid, "the pop-up does not share the process")

    harness.applet.selectTab(at: 0)
    spin(opener.webView)
    harness.applet.reload()
    timer.fire()

    await waitUntilGone(pid, in: harness, "the shared process ends")
    await harness.eventually("the pop-up lost its content") { popup.generation == 1 }

    XCTAssertFalse(popup.isMaterialized, "the pop-up is in the background, so it only waits")
    XCTAssertFalse(popup.isStopped)
    XCTAssertEqual(harness.count("GET", "/popup"), 1, "nothing reloaded by itself")
    XCTAssertEqual(opener.generation, 1)
  }

  /// Catches a spinning process left behind by a tab the user closes. The close arms no bound,
  /// since only a reload does. The probe never gets a reply, its bound runs out, and the process
  /// ends.
  func testClosingAHungTabEndsItsProcessWhenTheProbeGetsNoReply() async throws {
    let timer = ManualHangTimer()
    let log = SignalLog()
    let harness = try await make(hang: policy(timer, log: log))
    defer { harness.stop() }

    await harness.load("/a", expecting: "A")
    harness.applet.openTab()

    let hung = harness.applet.tabs[0]
    let pid = try XCTUnwrap(WebContent.processID(of: hung.webView))

    defer { if WebContent.isRunning(pid) { Darwin.kill(pid, SIGKILL) } }

    spin(hung.webView)

    let scheduled = timer.scheduled
    let result = await harness.applet.closeTab(at: 0)

    XCTAssertEqual(result, .closed)
    XCTAssertEqual(timer.scheduled, scheduled + 1, "the close armed one probe")
    XCTAssertTrue(WebContent.isRunning(pid), "the process ended before the bound ran out")
    XCTAssertTrue(log.pids.isEmpty)

    timer.fire()

    await waitUntilGone(pid, in: harness, "the closed tab's process ends")

    XCTAssertEqual(log.pids, [pid])
  }

  /// Catches a close that kills a process a live page uses, or keeps work after a close that
  /// needs none. A live page answers the probe at once, which cancels the bound. Firing the
  /// timer afterwards signals nothing. A pop-up sharing the process stays alive.
  func testClosingALivePageCancelsTheProbeAndSignalsNothing() async throws {
    let timer = ManualHangTimer()
    let log = SignalLog()
    let harness = try await make(hang: policy(timer, log: log))
    defer { harness.stop() }

    await harness.load("/a", expecting: "A")

    let opener = harness.tab
    let pid = try XCTUnwrap(WebContent.processID(of: opener.webView))

    defer { if WebContent.isRunning(pid) { Darwin.kill(pid, SIGKILL) } }

    await harness.run("window.open('/popup')")
    await harness.host.until("the pop-up opens") {
      harness.applet.tabCount == 2 && harness.applet.title == "POPUP"
    }

    let cancelled = timer.cancelled
    let result = await harness.applet.closeTab(at: 1)

    XCTAssertEqual(result, .closed)

    await harness.eventually("the reply cancels the probe") { timer.cancelled == cancelled + 1 }

    timer.fire()

    XCTAssertTrue(log.pids.isEmpty)
    XCTAssertTrue(WebContent.isRunning(pid))
    XCTAssertEqual(opener.generation, 0)

    let value = await harness.run("1 + 1") as? Int

    XCTAssertEqual(value, 2, "the opener's page stopped answering")
  }

  /// Catches a probe for a process the close already knows is dead. A tab that lost its process
  /// holds no web view, so closing it starts no work.
  func testClosingATabWhoseProcessAlreadyEndedStartsNoProbe() async throws {
    let timer = ManualHangTimer()
    let harness = try await make(hang: policy(timer))
    defer { harness.stop() }

    await harness.load("/a", expecting: "A")
    harness.applet.openTab()

    let stopped = harness.applet.tabs[0]

    await WebContent.kill(stopped.webView, in: harness)
    await harness.eventually("the tab lost its content") { stopped.generation == 1 }

    let scheduled = timer.scheduled
    let result = await harness.applet.closeTab(at: 0)

    XCTAssertEqual(result, .closed)
    XCTAssertEqual(timer.scheduled, scheduled)
  }
  /// Catches a close that kills a live tab. A pop-up shares its opener's process here. The opener
  /// runs a script that never ends, so the pop-up's probe gets no reply, and the bound runs out.
  /// The opener is busy, not hung, and the user closed only the pop-up. No signal goes out and the
  /// process lives on.
  func testClosingATabThatSharesItsProcessWithALiveBusyTabSignalsNothing() async throws {
    let timer = ManualHangTimer()
    let log = SignalLog()
    let harness = try await make(hang: policy(timer, log: log))
    defer { harness.stop() }

    await harness.load("/a", expecting: "A")

    let opener = harness.tab
    let pid = try XCTUnwrap(WebContent.processID(of: opener.webView))

    defer { if WebContent.isRunning(pid) { Darwin.kill(pid, SIGKILL) } }

    await harness.run("window.open('/popup')")
    await harness.host.until("the pop-up opens") {
      harness.applet.tabCount == 2 && harness.applet.title == "POPUP"
    }

    XCTAssertEqual(WebContent.processID(of: harness.tab.webView), pid, "the pop-up has no share")

    spin(opener.webView)

    let result = await harness.applet.closeTab(at: 1)

    XCTAssertEqual(result, .closed)

    timer.fire()

    for _ in 0..<200 { await Task.yield() }

    XCTAssertTrue(log.pids.isEmpty, "a live tab's process was signalled")
    XCTAssertTrue(WebContent.isRunning(pid))
  }

  /// Catches a skipped kill that leaves the process for good. After the pop-up's probe skipped, the
  /// opener closes. Its probe gets no reply and finds no other live tab, so it ends the process.
  func testTheLastLiveTabClosingEndsAProcessAnEarlierCloseLeftAlone() async throws {
    let timer = ManualHangTimer()
    let log = SignalLog()
    let harness = try await make(hang: policy(timer, log: log))
    defer { harness.stop() }

    await harness.load("/a", expecting: "A")

    let opener = harness.tab
    let pid = try XCTUnwrap(WebContent.processID(of: opener.webView))

    defer { if WebContent.isRunning(pid) { Darwin.kill(pid, SIGKILL) } }

    await harness.run("window.open('/popup')")
    await harness.host.until("the pop-up opens") {
      harness.applet.tabCount == 2 && harness.applet.title == "POPUP"
    }

    harness.applet.openTab()
    spin(opener.webView)

    _ = await harness.applet.closeTab(at: 1)

    timer.fire()

    for _ in 0..<200 { await Task.yield() }

    XCTAssertTrue(log.pids.isEmpty)

    let closed = await harness.applet.closeTab(at: 0)

    XCTAssertEqual(closed, .closed)

    timer.fire()

    await waitUntilGone(pid, in: harness, "the process ends with the last tab on it")

    XCTAssertEqual(log.pids, [pid])
  }

  /// Pins what a tab reopened inside the window does, as measured. The hung tab closes and its
  /// probe waits. The user reopens it at once. The reopened view gets a process of its own, so the
  /// probe still ends the spinning one, and the reopened tab is untouched and answers.
  func testATabReopenedInsideTheWindowGetsItsOwnProcessAndSurvivesTheKill() async throws {
    let timer = ManualHangTimer()
    let log = SignalLog()
    let harness = try await make(hang: policy(timer, log: log))
    defer { harness.stop() }

    await harness.load("/a", expecting: "A")
    harness.applet.openTab()

    let hung = harness.applet.tabs[0]
    let pid = try XCTUnwrap(WebContent.processID(of: hung.webView))

    defer { if WebContent.isRunning(pid) { Darwin.kill(pid, SIGKILL) } }

    spin(hung.webView)

    _ = await harness.applet.closeTab(at: 0)

    let stamp = try XCTUnwrap(harness.applet.closedTabStamps.last)

    _ = harness.applet.reopenTab(stamp: stamp)

    let reopened = harness.tab

    await harness.eventually("the reopened page loads") {
      reopened.currentURL?.path == "/a" && !reopened.isLoading
    }

    let fresh = try XCTUnwrap(WebContent.processID(of: reopened.webView))

    XCTAssertNotEqual(fresh, pid, "the reopened view joined the spinning process")

    timer.fire()

    await waitUntilGone(pid, in: harness, "the spinning process ends")

    XCTAssertEqual(log.pids, [pid])
    XCTAssertEqual(reopened.generation, 0)

    let value = await harness.run("1 + 1") as? Int

    XCTAssertEqual(value, 2, "the reopened tab died with the spinning process")
  }
}
