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

/// How the usage reader turns `proc_pid_rusage` processor time into nanoseconds. Apple silicon's
/// timebase is 125/3, so a reading in nanoseconds put through it grows 41.7 times, and the watch
/// would end an unused process doing little.
final class ProcessorTimeScaleTests: XCTestCase {
  private let appleSilicon = ProcessorTimeScale(numer: 125, denom: 3)

  /// Catches a reader that puts nanoseconds through the timebase. A release that reports
  /// nanoseconds must be read as nanoseconds.
  func testAReadingInNanosecondsIsReadAsNanoseconds() {
    let scale = ProcessorTimeScale.calibrated(
      raw: 2_000_000_000, reference: 2_000_000_000, timebase: appleSilicon)

    XCTAssertEqual(scale, .nanoseconds)
  }

  /// Catches a reader that stops converting ticks. Two seconds is 48 million ticks at 125/3.
  func testAReadingInTicksGoesThroughTheTimebase() {
    let scale = ProcessorTimeScale.calibrated(
      raw: 48_000_000, reference: 2_000_000_000, timebase: appleSilicon)

    XCTAssertEqual(scale, appleSilicon)
  }

  /// Catches a reader that guesses when neither scale matches, which could make an idle process
  /// read as busy. It answers nil, and the watch then signals nothing.
  func testAReadingThatMatchesNeitherScaleIsRefused() {
    XCTAssertNil(
      ProcessorTimeScale.calibrated(
        raw: 300_000_000, reference: 2_000_000_000, timebase: appleSilicon))
    XCTAssertNil(
      ProcessorTimeScale.calibrated(raw: 0, reference: 2_000_000_000, timebase: appleSilicon))
    XCTAssertNil(
      ProcessorTimeScale.calibrated(raw: 48_000_000, reference: 0, timebase: appleSilicon))
  }

  /// Catches a calibration that disagrees with this machine's kernel. Measured against this test
  /// run's own process, it picks the Mach timebase, which is what every shipped release reports.
  func testThisMachineCalibratesToItsTimebase() throws {
    var base = mach_timebase_info_data_t()
    mach_timebase_info(&base)

    let measured = try XCTUnwrap(WebContentProcess.processorScale)

    XCTAssertEqual(
      measured.nanoseconds(1_000_000), UInt64(1_000_000) * UInt64(base.numer) / UInt64(base.denom))
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

/// Reads a content process through the live sampler, and reports it as spinning a whole core.
///
/// Each reading keeps the live start time, the live time taken, and the live nil for a process
/// that is gone. Only the processor time is replaced, by the time taken, so any two readings of one
/// process read as one core between them. A closed tab's watch then decides on the real process,
/// and no load on the machine can starve the page under the watch's share. The cost is that a test
/// reading through it cannot show that a real spinning page reads busy.
///
/// The watch skips a process whose two readings carry the same time. So each reading must come
/// later than the one before it for the same process, or the test fails here. A test that expects
/// no signal cannot pass on that skip.
private final class BusySamples: Sendable {
  private let taken = Mutex<[pid_t: UInt64]>([:])

  func next(_ pid: pid_t) -> ProcessSample? {
    guard var reading = WebContentProcess.usage(pid) else { return nil }

    reading.processorNanoseconds = reading.takenNanoseconds

    let previous = taken.withLock { $0.updateValue(reading.takenNanoseconds, forKey: pid) }

    if let previous, reading.takenNanoseconds <= previous {
      XCTFail(
        "process \(pid) was read at \(reading.takenNanoseconds) ns, no later than its reading at "
          + "\(previous) ns, so the watch skips it")
    }

    return reading
  }
}

/// Reads a content process through the live sampler unchanged, and keeps every reading.
private final class LiveSamples: Sendable {
  private let readings = Mutex<[ProcessSample?]>([])

  var all: [ProcessSample?] { readings.withLock { $0 } }

  func next(_ pid: pid_t) -> ProcessSample? {
    let reading = WebContentProcess.usage(pid)

    readings.withLock { $0.append(reading) }

    return reading
  }
}

/// The share of one core a process used between two readings of it. The differences are taken in
/// floating point, so readings out of order give a negative share instead of trapping.
private func share(from first: ProcessSample, to last: ProcessSample) -> Double {
  (Double(last.processorNanoseconds) - Double(first.processorNanoseconds))
    / (Double(last.takenNanoseconds) - Double(first.takenNanoseconds))
}

/// This process's own processor time and uptime in nanoseconds, from readers the usage reader does
/// not use: the POSIX process CPU clock, and Foundation's system uptime. Each counts in units it
/// documents, so neither shares a conversion with the reading it brackets.
private struct OwnTimes {
  var processor: UInt64
  var uptime: UInt64

  static func now() -> OwnTimes {
    OwnTimes(
      processor: clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID),
      uptime: UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000_000))
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
///
/// A closed tab's watch reads a spinning page through `BusySamples`, so the share of a core the
/// page gets on a loaded machine never decides a test. None of those tests shows that a real
/// spinning page reads as busy.
@MainActor
final class BrowserHungProcessTests: XCTestCase {
  /// How far the independent readers may disagree with the usage reader. The process CPU clock
  /// counts whole microseconds of user and system time, so it can trail the kernel's own count by
  /// up to 2 µs. Measured over 100,000 brackets, idle and with a busy loop on every core, it
  /// trailed by at most 1.5 µs. The uptime reader never fell outside the bracket.
  ///
  /// A unit error is 41.7 times off, so it moves a reading by most of its own size. The test asks
  /// for at least 100 times the allowance of processor time, so that move dwarfs the allowance.
  private static let readerAllowance: UInt64 = 10_000

  private func make(hang: HangPolicy) async throws -> BrowserHarness {
    try await BrowserHarness.make(
      services: .testing(hang: hang), hosting: .focusedWindow,
      handler: { request in Pages.page(String(request.path.dropFirst()).uppercased()) })
  }

  private func spin(_ view: WKWebView) {
    view.evaluateJavaScript("while (true) {}", completionHandler: nil)
  }

  private func policy(
    _ timer: ManualHangTimer, log: SignalLog? = nil,
    sample: @escaping WebContentProcess.Sample = WebContentProcess.usage
  ) -> HangPolicy {
    var policy = timer.policy

    policy.process = WebContentProcess(
      sample: sample,
      signal: { pid, number in
        log?.record(pid, number)
        _ = Darwin.kill(pid, number)
      })

    return policy
  }

  private func waitUntilGone(_ pid: pid_t, in harness: BrowserHarness, _ what: String) async {
    await harness.eventually(what, seconds: 15) { !WebContent.isRunning(pid) }
  }

  /// A live sample compares a process's processor time with real time, so a test that reads an
  /// idle page live lets a third of a second pass between two readings.
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
  /// since only a reload does. Its watch reads the process as busy when the bound runs out, and
  /// the process ends. The bound fires right after the close, since the busy sample needs no time
  /// to pass.
  func testClosingASpinningTabEndsItsProcessWhenTheBoundRunsOut() async throws {
    let timer = ManualHangTimer()
    let log = SignalLog()
    let harness = try await make(hang: policy(timer, log: log, sample: BusySamples().next))
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

    timer.fire()

    await waitUntilGone(pid, in: harness, "the closed tab's process ends")

    XCTAssertEqual(log.pids, [pid])
  }

  /// Catches a live sample in the wrong units. The kernel reports processor time in Mach ticks, so
  /// a missed conversion reads 41.7 times too low on Apple silicon, and a needless one 41.7 times
  /// too high. The time taken must be uptime in nanoseconds too. A reading of this test's own
  /// process must fall between independent readings taken just before and just after it. So
  /// either field in the wrong units fails, and so do both with their ratio intact.
  ///
  /// The same page left idle also reads under the watch's share. Load cannot make an idle page
  /// read busy, so that side stays live. The test cannot show that a real spinning page reads busy,
  /// since that depends on how much of a core the machine gives it.
  func testTheLiveSampleIsInNanosecondsAndReadsAnIdlePageAsIdle() async throws {
    let harness = try await make(hang: policy(ManualHangTimer()))
    defer { harness.stop() }

    await harness.load("/a", expecting: "A")

    let pid = try XCTUnwrap(WebContent.processID(of: harness.tab.webView))

    defer { if WebContent.isRunning(pid) { Darwin.kill(pid, SIGKILL) } }

    let allowance = Self.readerAllowance
    let before = OwnTimes.now()
    let middle = try XCTUnwrap(WebContentProcess.usage(getpid()))
    let after = OwnTimes.now()

    XCTAssertGreaterThan(
      before.processor, 100 * allowance,
      "the process used too little processor time for the bracket to tell a unit error")
    XCTAssertGreaterThanOrEqual(
      middle.processorNanoseconds + allowance, before.processor,
      "the processor time read low, so a unit is off")
    XCTAssertLessThanOrEqual(
      middle.processorNanoseconds, after.processor + allowance,
      "the processor time read high, so a unit is off")
    XCTAssertGreaterThanOrEqual(
      middle.takenNanoseconds + allowance, before.uptime,
      "the time taken read low, so a unit is off")
    XCTAssertLessThanOrEqual(
      middle.takenNanoseconds, after.uptime + allowance,
      "the time taken read high, so a unit is off")

    let first = try XCTUnwrap(WebContentProcess.usage(pid))

    await letTimePass(in: harness)

    let last = try XCTUnwrap(WebContentProcess.usage(pid))

    XCTAssertEqual(first.started, last.started, "the process changed while it was read")
    XCTAssertLessThan(
      share(from: first, to: last), ClosedProcessWatch.busyShare, "an idle page read as spinning")
  }

  /// Catches a close that kills a process a live page uses, and a live sample that reads a closed
  /// tab's idle process as spinning. The closed pop-up was idle, and its opener still lives on the
  /// same process, so the bound running out signals nothing and the opener keeps answering. The
  /// watch reads the process live, and its readings at the close and at the fire must read idle.
  ///
  /// The idle guard and the live-tab check each stop the signal alone, since the opener shares the
  /// process. So the missing signal cannot show which of them held. The wait before the fire is a
  /// fixed third of a second, and never waits on what the page reads.
  func testClosingAnIdlePopUpSignalsNothing() async throws {
    let timer = ManualHangTimer()
    let log = SignalLog()
    let samples = LiveSamples()
    let harness = try await make(hang: policy(timer, log: log, sample: samples.next))
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

    let readings = samples.all

    XCTAssertEqual(readings.count, 2, "the watch read the process other than at the close and fire")

    let first = try XCTUnwrap(readings.first ?? nil, "the watch could not read the process")
    let last = try XCTUnwrap(readings.last ?? nil, "the watch could not read the process")

    XCTAssertEqual(first.started, last.started, "the process changed during the bound")
    XCTAssertLessThan(
      share(from: first, to: last), ClosedProcessWatch.busyShare,
      "the closed pop-up's idle process read as spinning")

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
  /// runs a script that never ends, so the process reads busy through the pop-up's bound. The
  /// opener is busy, not hung, and the user closed only the pop-up. No signal goes out and the
  /// process lives on. The busy sample takes the watch past its idle guard, so only the live-tab
  /// check stops the signal.
  func testClosingATabThatSharesItsProcessWithALiveBusyTabSignalsNothing() async throws {
    let timer = ManualHangTimer()
    let log = SignalLog()
    let harness = try await make(hang: policy(timer, log: log, sample: BusySamples().next))
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

    XCTAssertTrue(log.pids.isEmpty, "a live tab's process was signalled")
    XCTAssertTrue(WebContent.isRunning(pid))
  }

  /// Catches a skipped kill that leaves the process for good. After the pop-up's watch skipped, the
  /// opener closes. Its watch reads the process as busy with no other live tab, so it ends it. The
  /// busy sample takes the first watch past its idle guard, so only the live-tab check skips it.
  func testTheLastLiveTabClosingEndsAProcessAnEarlierCloseLeftAlone() async throws {
    let timer = ManualHangTimer()
    let log = SignalLog()
    let harness = try await make(hang: policy(timer, log: log, sample: BusySamples().next))
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

    XCTAssertTrue(log.pids.isEmpty, "a live tab's process was signalled")

    let closed = await harness.applet.closeTab(at: 0)

    XCTAssertEqual(closed, .closed)

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
    let harness = try await make(hang: policy(timer, log: log, sample: BusySamples().next))
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
