import Darwin
import Foundation
import OSLog
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
struct WebContentProcess: Sendable {
  typealias PathOf = @Sendable (pid_t) -> String?
  typealias Sample = @Sendable (pid_t) -> ProcessSample?
  typealias Signal = @Sendable (pid_t, Int32) -> Void

  var pathOf: PathOf
  var sample: Sample
  var signal: Signal

  init(
    pathOf: @escaping PathOf = WebContentProcess.executablePath,
    sample: @escaping Sample = WebContentProcess.usage, signal: @escaping Signal
  ) {
    self.pathOf = pathOf
    self.sample = sample
    self.signal = signal
  }

  static let live = WebContentProcess(signal: { pid, number in _ = Darwin.kill(pid, number) })

  private static let log = Logger(subsystem: "dev.uniterm.app", category: "browser")

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

  /// Sends SIGKILL to `pid` when it is a WebKit content process. Returns whether it signalled.
  @discardableResult
  func kill(_ pid: pid_t) -> Bool {
    guard pid > 1 else { return false }

    guard let path = pathOf(pid), path.contains(Self.pathMarker) else {
      Self.log.error("not ending process \(pid): it is not a WebKit content process")
      return false
    }

    signal(pid, SIGKILL)

    return true
  }

  /// Ends the content process a closed tab left, when no live web view in the app uses it. A busy
  /// page is not a hung one, and a tab that shares the process may be busy. Returns whether it
  /// signalled.
  @MainActor
  @discardableResult
  func killUnused(_ pid: pid_t) -> Bool {
    guard !LiveContentViews.contains(where: { identifier(of: $0) == pid }) else {
      Self.log.notice("not ending process \(pid): a live tab shares it")
      return false
    }

    return kill(pid)
  }

  /// Reads a process's start time and processor time with `proc_pid_rusage`. Nil when the process
  /// is gone or not this user's.
  ///
  /// The kernel reports processor time in Mach ticks, so the timebase converts it to nanoseconds.
  /// A release that reported nanoseconds instead would make a spinning process read as idle, and
  /// the watch would then signal nothing rather than something wrong.
  static let usage: Sample = { pid in
    var info = rusage_info_v0()
    let status = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
        proc_pid_rusage(pid, RUSAGE_INFO_V0, $0)
      }
    }

    guard status == 0 else { return nil }

    var base = mach_timebase_info_data_t()
    mach_timebase_info(&base)

    let ticks = info.ri_user_time + info.ri_system_time

    return ProcessSample(
      started: info.ri_proc_start_abstime,
      processorNanoseconds: ticks * UInt64(base.numer) / UInt64(base.denom),
      takenNanoseconds: clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
  }

  static let executablePath: PathOf = { pid in
    var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))

    guard length > 0 else { return nil }

    return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }
}

/// One reading of a process. The start time tells a recycled id apart from the process it once
/// named. Both times are in nanoseconds, so their differences compare.
struct ProcessSample: Equatable, Sendable {
  var started: UInt64
  var processorNanoseconds: UInt64
  var takenNanoseconds: UInt64
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
@MainActor
enum ClosedProcessWatch {
  /// The share of one core a process must use over the bound to count as spinning. A page in an
  /// endless loop uses a whole core, and half leaves room for a loaded machine.
  static let busyShare = 0.5

  /// Starts the watch. The caller reads `pid` before the view is released.
  static func watch(pid: pid_t, policy: HangPolicy) {
    let process = policy.process

    guard let first = process.sample(pid) else { return }

    _ = policy.schedule(policy.bound) { expired(pid: pid, first: first, process: process) }
  }

  private static func expired(pid: pid_t, first: ProcessSample, process: WebContentProcess) {
    guard let last = process.sample(pid), last.started == first.started,
      last.takenNanoseconds > first.takenNanoseconds,
      last.processorNanoseconds >= first.processorNanoseconds
    else { return }

    let elapsed = Double(last.takenNanoseconds - first.takenNanoseconds)
    let used = Double(last.processorNanoseconds - first.processorNanoseconds)

    guard used >= busyShare * elapsed else { return }

    process.killUnused(pid)
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
