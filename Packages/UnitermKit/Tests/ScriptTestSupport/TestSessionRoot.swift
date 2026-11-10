import Darwin
import PaneModel
import ProcessInspection
import ScriptHost

/// The test process standing in for a terminal session root, so the helpers a test starts and the
/// raw peers it connects descend from a recorded root.
///
/// In the app, only a terminal's report of the process it spawned records a root. Tests record the
/// test process through here and nowhere else, so that exception stays in one place.
public enum TestSessionRoot {
  /// The test process's identity.
  public static var identity: ProcessIdentity {
    ProcessIdentity(pid: getpid(), started: ProcessInspection.startTime(of: getpid()) ?? 0)
  }

  /// Records the test process as the session root of a pane.
  @MainActor
  public static func record(
    in host: ScriptHost, generation: UInt64 = 1, window: UInt64 = 1,
    pane: NodeID = NodeID(rawValue: 1)
  ) {
    host.recordSessionRoot(identity, sessionGeneration: generation, window: window, pane: pane)
  }

  /// Removes the record that `record` made.
  @MainActor
  public static func remove(
    from host: ScriptHost, window: UInt64 = 1, pane: NodeID = NodeID(rawValue: 1)
  ) {
    host.removeSessionRoot(identity, window: window, pane: pane)
  }

  /// Tells a REPL channel that its helper runs under the test process.
  @MainActor
  public static func set(on channel: ScriptReplChannel, generation: UInt64 = 1) {
    channel.setSessionRoot(identity, generation: generation)
  }
}
