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
  typealias Signal = @Sendable (pid_t, Int32) -> Void

  var pathOf: PathOf
  var signal: Signal

  init(pathOf: @escaping PathOf = WebContentProcess.executablePath, signal: @escaping Signal) {
    self.pathOf = pathOf
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

  /// Ends the content process that a closed `view` had, when the process id still names that
  /// process and no live web view in the app uses it. A busy page is not a hung one, and a tab
  /// that shares the process with the closed view may be busy. Returns whether it signalled.
  @MainActor
  @discardableResult
  func kill(_ pid: pid_t, closedView view: WKWebView) -> Bool {
    guard identifier(of: view) == pid else { return false }

    guard !LiveContentViews.contains(where: { identifier(of: $0) == pid }) else {
      Self.log.notice("not ending process \(pid): a live tab shares it")
      return false
    }

    return kill(pid)
  }

  static let executablePath: PathOf = { pid in
    var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))

    guard length > 0 else { return nil }

    return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }
}

/// Watches a web view that a closed tab let go of, and ends its content process when the process
/// never answers.
///
/// A tab that closes while its page spins never arms the hang bound, since the bound belongs to a
/// user's reload. The close leaves the spinning process behind. This probe asks the page a trivial
/// question. A reply from the page, or an error that says the process ended, ends the watch. No
/// reply within the policy's bound ends the process.
///
/// The probe keeps the web view alive until the watch ends. A released view answers every pending
/// call at once, which would look like a reply. The work kept after a close is therefore bounded by
/// the policy's bound, and a page that answers is released within a round trip.
@MainActor
final class ClosedViewProbe {
  private var view: WKWebView?
  private var cancelBound: HangPolicy.Cancel?
  private let pid: pid_t
  private let process: WebContentProcess

  /// Starts the watch. The caller reads `pid` before the view is released.
  static func watch(_ view: WKWebView, pid: pid_t, policy: HangPolicy) {
    _ = ClosedViewProbe(view, pid: pid, policy: policy)
  }

  private init(_ view: WKWebView, pid: pid_t, policy: HangPolicy) {
    self.view = view
    self.pid = pid
    self.process = policy.process

    cancelBound = policy.schedule(policy.bound) { [self] in expired() }

    view.evaluateJavaScript("0") { [self] _, _ in finish() }
  }

  private func finish() {
    cancelBound?()
    cancelBound = nil
    view = nil
  }

  private func expired() {
    guard let view else { return }

    cancelBound = nil

    process.kill(pid, closedView: view)

    self.view = nil
  }
}

/// The web views that tabs hold now, across every browser pane. A closed tab's view is not in it,
/// even while a probe keeps that view alive. Browser panes share one website data store, so a
/// content process can serve a tab in another pane, and only a registry of the whole app can say
/// whether a process is in use.
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
