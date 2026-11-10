import Darwin
import Foundation
import ProcessInspection

/// Walks the process tree to check if a process is a descendant of a recorded session root.
public struct ProcessAncestry {
  /// Checks if the given process is a descendant of any recorded session root in the registry.
  /// Returns the matching root's identity if found, or nil if no ancestry is established.
  ///
  /// Fails closed when process information is unavailable or ambiguous.
  @MainActor
  public static func findRoot(
    for process: ProcessIdentity, in registry: SessionRootRegistry
  ) -> ProcessIdentity? {
    var current = process

    for _ in 0..<100 {
      if registry.contains(current) {
        return current
      }

      guard let parent = ProcessInspection.parent(of: current.pid) else { return nil }

      current = ProcessIdentity(pid: parent.pid, started: parent.started)
    }

    return nil
  }
}
