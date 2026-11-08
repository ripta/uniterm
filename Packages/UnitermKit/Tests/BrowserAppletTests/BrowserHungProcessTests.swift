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

/// Hands out a fixed list of samples, one per read, then nil.
private final class Samples: Sendable {
  private let queue: Mutex<[ProcessSample?]>

  init(_ samples: [ProcessSample?]) {
    queue = Mutex(samples)
  }

  func next(_: pid_t) -> ProcessSample? {
    queue.withLock { $0.isEmpty ? nil : $0.removeFirst() }
  }
}

/// The decision a closed tab's watch makes when its bound runs out, from samples a test supplies.
/// The integration tests below spin real pages. These pin each reason to leave a process alone.
@MainActor
final class ClosedProcessWatchTests: XCTestCase {
  private static let second: UInt64 = 1_000_000_000

  private func sample(started: UInt64 = 7, processor: Double, at: Double) -> ProcessSample {
    ProcessSample(
      started: started, processorNanoseconds: UInt64(processor * Double(Self.second)),
      takenNanoseconds: UInt64(at * Double(Self.second)))
  }

  /// Arms a watch for a closed tab, runs its bound out, and returns what it signalled.
  private func signals(for samples: [ProcessSample?]) -> (pids: [pid_t], scheduled: Int) {
    let log = SignalLog()
    let feed = Samples(samples)
    let timer = ManualHangTimer()
    var policy = timer.policy

    policy.process = WebContentProcess(
      pathOf: { _ in "/x/com.apple.WebKit.WebContent.xpc/Contents/MacOS/x" }, sample: feed.next,
      signal: log.record)

    ClosedProcessWatch.watch(pid: 4242, policy: policy)
    timer.fire()

    return (log.pids, timer.scheduled)
  }

  /// Catches a watch that leaves a spinning process behind. Nine and a half seconds of processor
  /// time over a ten-second bound is a page in an endless loop.
  func testAProcessThatSpinsThroughTheBoundEnds() {
    let result = signals(for: [sample(processor: 1, at: 0), sample(processor: 10.5, at: 10)])

    XCTAssertEqual(result.pids, [4242])
  }

  /// Catches a watch that ends a process doing nothing. WebKit keeps idle processes for reuse, and
  /// one that is not spinning costs nothing.
  func testAnIdleProcessIsLeftAlone() {
    let result = signals(for: [sample(processor: 1, at: 0), sample(processor: 1.2, at: 10)])

    XCTAssertTrue(result.pids.isEmpty)
  }

  /// Catches a kill that reaches a process which took over the id. A process that started at
  /// another time is not the one the tab left, however busy it is.
  func testARecycledIdIsLeftAlone() {
    let result = signals(for: [
      sample(started: 7, processor: 1, at: 0), sample(started: 8, processor: 10, at: 10),
    ])

    XCTAssertTrue(result.pids.isEmpty)
  }

  /// Catches a signal to an id with nothing behind it. A process that ended during the bound
  /// cannot be read again, and the watch stops there.
  func testAProcessThatEndedDuringTheBoundIsLeftAlone() {
    let result = signals(for: [sample(processor: 1, at: 0), nil])

    XCTAssertTrue(result.pids.isEmpty)
  }

  /// Catches work armed for a process that is already gone at the close.
  func testAProcessGoneAtTheCloseArmsNoBound() {
    let result = signals(for: [nil])

    XCTAssertTrue(result.pids.isEmpty)
    XCTAssertEqual(result.scheduled, 0)
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

  /// A closed tab's watch compares the process's processor time with real time, so a test lets a
  /// third of a second pass between a close and the bound it fires by hand.
  private func letTimePass(in harness: BrowserHarness) async {
    let until = Date().addingTimeInterval(0.3)

    await harness.eventually("a third of a second passes", seconds: 5) { Date() >= until }
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

  /// Catches a spinning process left behind by a tab the user closes. The close arms no hang bound,
  /// since only a reload does. Its watch finds the process spinning when the bound runs out, and
  /// the process ends.
  func testClosingASpinningTabEndsItsProcessWhenTheBoundRunsOut() async throws {
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
    XCTAssertEqual(timer.scheduled, scheduled + 1, "the close armed one watch")
    XCTAssertTrue(WebContent.isRunning(pid), "the process ended before the bound ran out")
    XCTAssertTrue(log.pids.isEmpty)

    await letTimePass(in: harness)
    timer.fire()

    await waitUntilGone(pid, in: harness, "the closed tab's process ends")

    XCTAssertEqual(log.pids, [pid])
  }

  /// Catches a live sample in the wrong units. The kernel reports processor time in Mach ticks, so
  /// a missed conversion makes a spinning page read about 41 times faster than real time on Apple
  /// silicon. A spinning page reads at least the watch's share of a core and at most about one
  /// core, and the same page idle reads under the share.
  func testTheLiveSampleReadsASpinningPageAsBusyAndAnIdleOneAsNot() async throws {
    let harness = try await make(hang: policy(ManualHangTimer()))
    defer { harness.stop() }

    await harness.load("/a", expecting: "A")

    let pid = try XCTUnwrap(WebContent.processID(of: harness.tab.webView))

    defer { if WebContent.isRunning(pid) { Darwin.kill(pid, SIGKILL) } }

    func share() async throws -> Double {
      let first = try XCTUnwrap(WebContentProcess.usage(pid))

      await letTimePass(in: harness)

      let last = try XCTUnwrap(WebContentProcess.usage(pid))

      XCTAssertEqual(first.started, last.started, "the process changed while it was read")

      return Double(last.processorNanoseconds - first.processorNanoseconds)
        / Double(last.takenNanoseconds - first.takenNanoseconds)
    }

    let idle = try await share()

    spin(harness.tab.webView)

    let busy = try await share()

    XCTAssertLessThan(idle, ClosedProcessWatch.busyShare, "an idle page read as spinning")
    XCTAssertGreaterThanOrEqual(busy, ClosedProcessWatch.busyShare, "a spinning page read as idle")
    XCTAssertLessThanOrEqual(busy, 1.5, "processor time ran ahead of real time, so a unit is off")
  }

  /// Catches a close that kills a process a live page uses. The closed pop-up was idle, and its
  /// opener still lives on the same process, so the bound running out signals nothing and the
  /// opener keeps answering.
  func testClosingAnIdlePopUpSignalsNothing() async throws {
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

    let scheduled = timer.scheduled
    let result = await harness.applet.closeTab(at: 1)

    XCTAssertEqual(result, .closed)
    XCTAssertEqual(timer.scheduled, scheduled + 1, "the close armed one watch")

    await letTimePass(in: harness)
    timer.fire()

    XCTAssertTrue(log.pids.isEmpty)
    XCTAssertTrue(WebContent.isRunning(pid))
    XCTAssertEqual(opener.generation, 0)

    let value = await harness.run("1 + 1") as? Int

    XCTAssertEqual(value, 2, "the opener's page stopped answering")
  }

  /// Catches a watch for a process the close already knows is dead. A tab that lost its process
  /// holds no web view, so closing it starts no work.
  func testClosingATabWhoseProcessAlreadyEndedStartsNoWatch() async throws {
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
  /// runs a script that never ends, so the process spins through the pop-up's bound. The opener is
  /// busy, not hung, and the user closed only the pop-up. No signal goes out and the process lives
  /// on.
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

    await letTimePass(in: harness)
    timer.fire()

    XCTAssertTrue(log.pids.isEmpty, "a live tab's process was signalled")
    XCTAssertTrue(WebContent.isRunning(pid))
  }

  /// Catches a skipped kill that leaves the process for good. After the pop-up's watch skipped, the
  /// opener closes. Its watch finds the process spinning and no other live tab, so it ends it.
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

    await letTimePass(in: harness)
    timer.fire()

    XCTAssertTrue(log.pids.isEmpty)

    let closed = await harness.applet.closeTab(at: 0)

    XCTAssertEqual(closed, .closed)

    await letTimePass(in: harness)
    timer.fire()

    await waitUntilGone(pid, in: harness, "the process ends with the last tab on it")

    XCTAssertEqual(log.pids, [pid])
  }

  /// Pins what a tab reopened inside the window does, as measured. The hung tab closes and its
  /// watch waits. The user reopens it at once. The reopened view gets a process of its own, so the
  /// watch still ends the spinning one, and the reopened tab is untouched and answers.
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

    await letTimePass(in: harness)
    timer.fire()

    await waitUntilGone(pid, in: harness, "the spinning process ends")

    XCTAssertEqual(log.pids, [pid])
    XCTAssertEqual(reopened.generation, 0)

    let value = await harness.run("1 + 1") as? Int

    XCTAssertEqual(value, 2, "the reopened tab died with the spinning process")
  }
}
