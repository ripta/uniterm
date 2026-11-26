import Darwin
import Foundation
import OSLog
import ProcessInspection
import WebKit

/// Reads the id of a web view's content process and ends the process with SIGKILL.
///
/// This is the one place the product uses private WebKit API. A spinning page keeps its content
/// process running after its web view is released, a non-persistent store, a navigation to
/// `about:blank`, and WebKit's own private close and kill calls. A signal to the process id is the
/// only measured way to end it.
///
/// The read uses `_webProcessIdentifier`, behind `responds(to:)`. A macOS release that drops the
/// property makes `identifier(of:)` return nil, so nothing is signalled and a hung process outlives
/// its view as it did before.
///
/// A signal to the wrong process is worse than no signal, so `kill` refuses what is not a content
/// process. `kill(0, ...)` signals this process's own group. Ids at or below 1 are never signalled.
/// The path of the process must also name a WebKit content process, so a recycled id that now
/// belongs to something else is left alone.
///
/// A kill names its process by the id and the microsecond it started, read when the product
/// learned the id. The signal goes through `ProcessInspection`'s guarded call, which sends it only
/// while that pair still names a live process. So an id the system handed to another process after
/// the path check is left alone too.
struct WebContentProcess: Sendable {
  typealias PathOf = @Sendable (pid_t) -> String?
  typealias Sample = @Sendable (pid_t) -> ProcessSample?
  typealias Identify = @Sendable (pid_t) -> ContentProcessIdentity?
  typealias Signal = @Sendable (ContentProcessIdentity, Int32) -> ProcessInspection.SignalResult

  var pathOf: PathOf
  var sample: Sample
  var identify: Identify
  var signal: Signal

  init(
    pathOf: @escaping PathOf = WebContentProcess.executablePath,
    sample: @escaping Sample = WebContentProcess.usage,
    identify: @escaping Identify = WebContentProcess.startIdentity,
    signal: @escaping Signal = WebContentProcess.guardedSignal
  ) {
    self.pathOf = pathOf
    self.sample = sample
    self.identify = identify
    self.signal = signal
  }

  static let live = WebContentProcess()

  private static let log = Logger(subsystem: "dev.uniterm.app", category: "browser")

  /// Reads the identity of the process `pid` names now. Nil when it is gone or a zombie.
  static let startIdentity: Identify = { pid in
    ProcessInspection.startTimeMicroseconds(of: pid).map {
      ContentProcessIdentity(pid: pid, startedMicroseconds: $0)
    }
  }

  static let guardedSignal: Signal = { identity, number in
    ProcessInspection.signal(
      number, pid: identity.pid, startedMicroseconds: identity.startedMicroseconds)
  }

  /// The substring that every WebKit content process path carries, including the development
  /// builds that a debug run of WebKit uses.
  static let pathMarker = "com.apple.WebKit.WebContent"

  /// The content process of `view`, or nil when it has none yet or this macOS does not report it.
  @MainActor
  func identifier(of view: WKWebView) -> pid_t? {
    let name = "_webProcessIdentifier"

    guard view.responds(to: NSSelectorFromString(name)),
      let number = view.value(forKey: name) as? NSNumber
    else { return nil }

    let pid = pid_t(number.int32Value)

    return pid > 1 ? pid : nil
  }

  /// The content process of `view` with the time it started, or nil when it has none or the
  /// process is already gone.
  @MainActor
  func identity(of view: WKWebView) -> ContentProcessIdentity? {
    identifier(of: view).flatMap(identify)
  }

  /// Sends SIGKILL to the process `identity` names when it is a WebKit content process. Returns
  /// whether it signalled. A process the guarded call reports gone, unreached, or refused was not
  /// signalled.
  @discardableResult
  func kill(_ identity: ContentProcessIdentity) -> Bool {
    let pid = identity.pid

    guard pid > 1 else { return false }

    guard let path = pathOf(pid), path.contains(Self.pathMarker) else {
      Self.log.error("not ending process \(pid): it is not a WebKit content process")
      return false
    }

    switch signal(identity, SIGKILL) {
    case .byToken:
      return true

    case .byPid:
      Self.log.notice("ended process \(pid) by its id: the system gave no audit token")
      return true

    case .gone:
      return false

    case .unreached:
      Self.log.error("could not end process \(pid): the signal did not reach it")
      return false

    case .refused:
      Self.log.error("not ending process \(pid): the id is never signalled")
      return false
    }
  }

  /// Ends the content process a closed tab left, when no live web view in the app uses it. A busy
  /// page is not a hung one, and a tab that shares the process may be busy. Returns whether it
  /// signalled.
  ///
  /// Live views are compared by id alone, and no token is read for them. A live view on the id
  /// means a tab uses that process, whichever process it is now.
  @MainActor
  @discardableResult
  func killUnused(_ identity: ContentProcessIdentity) -> Bool {
    let pid = identity.pid

    guard !LiveContentViews.contains(where: { identifier(of: $0) == pid }) else {
      Self.log.notice("not ending process \(pid): a live tab shares it")
      return false
    }

    return kill(identity)
  }

  /// Reads a process's start time and processor time with `proc_pid_rusage`. Nil when the process
  /// is gone or not this user's, or when `processorScale` could not tell the kernel's units.
  ///
  /// The units come from `processorScale`, measured against this process's own time. A wrong unit
  /// would read an unused process as busy, or a spinning one as idle. When the units cannot be
  /// told, every read is nil and the watch signals nothing.
  static let usage: Sample = { pid in
    guard let scale = processorScale else { return nil }

    var info = rusage_info_v0()
    let status = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
        proc_pid_rusage(pid, RUSAGE_INFO_V0, $0)
      }
    }

    guard status == 0 else { return nil }

    return ProcessSample(
      started: info.ri_proc_start_abstime,
      processorNanoseconds: scale.nanoseconds(info.ri_user_time + info.ri_system_time),
      takenNanoseconds: clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
  }

  /// The scale for `proc_pid_rusage` processor time, measured once against this process's own
  /// time from `getrusage`. Nil when the two disagree with every scale.
  static let processorScale: ProcessorTimeScale? = {
    var info = rusage_info_v0()
    let status = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
        proc_pid_rusage(getpid(), RUSAGE_INFO_V0, $0)
      }
    }

    var own = rusage()

    guard status == 0, getrusage(RUSAGE_SELF, &own) == 0 else { return nil }

    var base = mach_timebase_info_data_t()
    mach_timebase_info(&base)

    let microseconds =
      (UInt64(own.ru_utime.tv_sec) + UInt64(own.ru_stime.tv_sec)) * 1_000_000
      + UInt64(own.ru_utime.tv_usec) + UInt64(own.ru_stime.tv_usec)

    return ProcessorTimeScale.calibrated(
      raw: info.ri_user_time + info.ri_system_time, reference: microseconds * 1_000,
      timebase: ProcessorTimeScale(numer: UInt64(base.numer), denom: UInt64(base.denom)))
  }()

  static let executablePath: PathOf = { pid in
    var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))

    guard length > 0 else { return nil }

    return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }
}

/// How processor time from `proc_pid_rusage` becomes nanoseconds: multiply by `numer`, divide by
/// `denom`.
struct ProcessorTimeScale: Equatable, Sendable {
  var numer: UInt64
  var denom: UInt64

  static let nanoseconds = ProcessorTimeScale(numer: 1, denom: 1)

  func nanoseconds(_ units: UInt64) -> UInt64 {
    units * numer / denom
  }

  /// The scale that reads `raw`, this process's own processor time from `proc_pid_rusage`, as
  /// `reference`, the same time in nanoseconds from `getrusage`. The kernel has reported Mach
  /// ticks, which need the timebase, and a release could report nanoseconds instead.
  ///
  /// Nil when neither scale lands within `tolerance` of the reference. A guess could read an idle
  /// process as busy, and a nil scale makes the watch signal nothing.
  static func calibrated(raw: UInt64, reference: UInt64, timebase: ProcessorTimeScale)
    -> ProcessorTimeScale?
  {
    guard raw > 0, reference > 0 else { return nil }

    let candidates = timebase == .nanoseconds ? [timebase] : [timebase, .nanoseconds]
    let target = Double(reference)

    let fits = candidates.filter { scale in
      let ratio = Double(scale.nanoseconds(raw)) / target

      return ratio >= 1 / tolerance && ratio <= tolerance
    }

    return fits.count == 1 ? fits.first : nil
  }

  /// How far a scale's reading may stray from the reference and still match. The two reads happen
  /// a moment apart and `getrusage` counts microseconds, so they never agree exactly. The 41.7
  /// times gap between the two scales on Apple silicon leaves room for both.
  static let tolerance = 2.0
}

/// One reading of a process. The start time tells a recycled id apart from the process it once
/// named. Both times are in nanoseconds, so their differences compare.
struct ProcessSample: Equatable, Sendable {
  var started: UInt64
  var processorNanoseconds: UInt64
  var takenNanoseconds: UInt64
}

/// A content process as a kill names it: its id, and the microsecond it started.
struct ContentProcessIdentity: Equatable, Sendable {
  var pid: pid_t
  var startedMicroseconds: Int
}

/// Watches the content process a closed tab let go of, and ends it when it spins with no tab left.
///
/// A tab that closes while its page spins never arms the hang bound, since the bound belongs to a
/// user's reload, so the close would leave the spinning process behind. The close releases the
/// view at once and keeps only the process id. Holding a closed, detached view until its process
/// answered a script call crashed WebKit on macOS 26.7 when that process died.
///
/// The watch samples the process at the close, and again when the policy's bound runs out. It ends
/// the process only when the same process is still there, used at least `busyShare` of a core over
/// the bound, and no live tab uses it. An idle process is left for WebKit to end.
///
/// The process's identity is read at the close, and the kill names that identity at the fire.
@MainActor
enum ClosedProcessWatch {
  /// The share of one core a process must use over the bound to count as spinning. A page in an
  /// endless loop uses a whole core, and half leaves room for a loaded machine.
  static let busyShare = 0.5

  /// Starts the watch. The caller reads `pid` before the view is released.
  static func watch(pid: pid_t, policy: HangPolicy) {
    let process = policy.process

    guard let first = process.sample(pid), let identity = process.identify(pid) else { return }

    _ = policy.schedule(policy.bound) {
      expired(identity: identity, first: first, process: process)
    }
  }

  private static func expired(
    identity: ContentProcessIdentity, first: ProcessSample, process: WebContentProcess
  ) {
    guard let last = process.sample(identity.pid), last.started == first.started,
      last.takenNanoseconds > first.takenNanoseconds,
      last.processorNanoseconds >= first.processorNanoseconds
    else { return }

    let elapsed = Double(last.takenNanoseconds - first.takenNanoseconds)
    let used = Double(last.processorNanoseconds - first.processorNanoseconds)

    guard used >= busyShare * elapsed else { return }

    process.killUnused(identity)
  }
}

/// The web views that tabs hold now, across every browser pane. A closed tab's view is not in it.
/// Browser panes share one website data store, so a content process can serve a tab in another
/// pane, and only a registry of the whole app can say whether a process is in use.
@MainActor
enum LiveContentViews {
  private static let views = NSHashTable<WKWebView>.weakObjects()

  static func add(_ view: WKWebView) {
    views.add(view)
  }

  static func remove(_ view: WKWebView) {
    views.remove(view)
  }

  static func contains(where match: (WKWebView) -> Bool) -> Bool {
    views.allObjects.contains(where: match)
  }
}
