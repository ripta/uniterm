import Foundation

/// Tracks the spawned session roots reported by terminal surfaces. A session root is the direct
/// child process spawned by libghostty, which is `/usr/bin/login` in both shell and program mode.
///
/// Authority checking walks from a connecting process up to a recorded session root. A process that
/// is not a descendant of any recorded root is unbound and needs explicit user grant.
@MainActor
public final class SessionRootRegistry {
  private var roots: [ProcessIdentity: SessionRoot] = [:]

  public init() {}

  public struct SessionRoot: Equatable {
    public let identity: ProcessIdentity
    public let sessionGeneration: UInt64

    public init(identity: ProcessIdentity, sessionGeneration: UInt64) {
      self.identity = identity
      self.sessionGeneration = sessionGeneration
    }
  }

  /// Records a session root reported by a terminal surface.
  public func add(_ root: SessionRoot) {
    roots[root.identity] = root
  }

  /// Removes a session root when its terminal session closes or is replaced.
  public func remove(_ identity: ProcessIdentity) {
    roots[identity] = nil
  }

  /// True if the given process identity is a recorded session root.
  public func contains(_ identity: ProcessIdentity) -> Bool {
    guard let recorded = roots[identity] else { return false }

    return recorded.identity.isRunning
  }

  /// Returns the session generation for a recorded root, or nil if not found or no longer running.
  public func sessionGeneration(for identity: ProcessIdentity) -> UInt64? {
    guard let recorded = roots[identity], recorded.identity.isRunning else { return nil }

    return recorded.sessionGeneration
  }

  /// Removes all roots that are no longer running.
  public func removeStale() {
    roots = roots.filter { $0.value.identity.isRunning }
  }
}
