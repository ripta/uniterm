import Dispatch
import Foundation
import ProcessInspection

/// The programs that run a session on another host. Output written while one of them runs in a
/// pane may name files that exist only there, so a click on a path in that pane opens nothing.
///
/// This is the one list. It matches the name the kernel keeps for a process, and the last
/// component of its executable path. A client that is not listed, such as `kubectl exec`,
/// `docker exec`, or `ssh` inside a local tmux, still looks local.
enum RemoteClients {
  static let names: Set<String> = [
    "ssh", "mosh-client", "mosh", "telnet", "rlogin", "rsh", "et", "autossh",
  ]

  static func isRemoteClient(_ name: String) -> Bool {
    names.contains(name)
  }
}

/// How the watcher reads the process table. Tests replace it with a table they step by hand.
struct ProcessTable: Sendable {
  var children: @Sendable (pid_t) -> [pid_t]

  /// The names a process answers to. Empty when the process is gone.
  var names: @Sendable (pid_t) -> [String]

  static let live = ProcessTable(
    children: { ProcessInspection.children(of: $0) },
    names: { pid in
      var result: [String] = []

      if let name = ProcessInspection.name(of: pid) { result.append(name) }

      if let path = ProcessInspection.executablePath(of: pid) {
        result.append((path as NSString).lastPathComponent)
      }

      return result
    })
}

/// Watches a terminal session's process tree for a remote client. It stops once it finds one, since
/// the marker it sets never clears.
protocol RemoteClientWatching: AnyObject, Sendable {
  func stop()
}

/// Makes a watcher for a session root. The callback gets the client's name, on any thread.
typealias RemoteWatcherFactory =
  @MainActor (_ root: pid_t, _ found: @escaping @Sendable (String) -> Void) ->
  any RemoteClientWatching

/// Finds a remote client among the descendants of a session's root process.
///
/// Every process in the tree is watched for fork, exec, and exit, through the kernel's process
/// events. Each event rescans the tree. The scan watches any process it has not seen, then reads
/// the names. The names are read after the watch is set, so a process that execs the client
/// between the listing and the watch is still seen. A client that starts and exits between two
/// scans is missed.
///
/// A process the system will not let the watcher observe gives no events. The slow timer rescans
/// the tree for that case, so a client below such a process is found at the next tick.
///
/// All state lives on one serial queue. Nothing runs on the main thread.
final class RemoteClientWatcher: RemoteClientWatching, @unchecked Sendable {
  /// A bound on the tree one scan walks, so a fork bomb cannot make the scan unbounded.
  static let treeLimit = 4096

  private let queue = DispatchQueue(label: "dev.uniterm.remote-clients")
  private let root: pid_t
  private let table: ProcessTable
  private let found: @Sendable (String) -> Void
  private var sources: [pid_t: any DispatchSourceProcess] = [:]
  private var timer: (any DispatchSourceTimer)?
  private var finished = false

  /// Starts watching at once. The first scan runs on the watcher's queue. A nil `pollInterval`
  /// leaves only the process events, which tests use.
  init(
    root: pid_t, table: ProcessTable = .live, pollInterval: TimeInterval? = 2,
    found: @escaping @Sendable (String) -> Void
  ) {
    self.root = root
    self.table = table
    self.found = found

    queue.async { [self] in
      scan()

      if let pollInterval, !finished {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        timer.setEventHandler { [weak self] in self?.scan() }
        timer.resume()
        self.timer = timer
      }
    }
  }

  deinit {
    for source in sources.values { source.cancel() }

    timer?.cancel()
  }

  func stop() {
    queue.async { [self] in
      finish()
    }
  }

  /// Rescans now, as a process event would. Tests call it after they change the table.
  func rescan() {
    queue.async { [self] in
      scan()
    }
  }

  /// Runs every queued scan, so a test can read the result.
  func drain() {
    queue.sync {}
  }

  private func scan() {
    guard !finished else { return }

    var seen = Set<pid_t>()
    var pending = [root]
    var client: String?

    while let pid = pending.popLast() {
      guard seen.count < Self.treeLimit, seen.insert(pid).inserted else { continue }

      if sources[pid] == nil { watch(pid) }

      if client == nil {
        client = table.names(pid).first(where: RemoteClients.isRemoteClient)
      }

      pending.append(contentsOf: table.children(pid))
    }

    for pid in sources.keys where !seen.contains(pid) {
      sources.removeValue(forKey: pid)?.cancel()
    }

    guard let client else { return }

    finish()
    found(client)
  }

  private func watch(_ pid: pid_t) {
    let source = DispatchSource.makeProcessSource(
      identifier: pid, eventMask: [.fork, .exec, .exit], queue: queue)
    source.setEventHandler { [weak self] in self?.scan() }
    source.resume()
    sources[pid] = source
  }

  private func finish() {
    finished = true

    for source in sources.values { source.cancel() }

    sources = [:]
    timer?.cancel()
    timer = nil
  }
}
