import AppletKit
import Foundation
import PaneModel

/// How many closes a window remembers.
public struct CloseUndoPolicy: Sendable, Equatable {
  public var stackDepth: Int

  public init(stackDepth: Int) {
    self.stackDepth = stackDepth
  }

  public static let standard = CloseUndoPolicy(stackDepth: 20)
}

/// A closed pane, as undo needs it: where it sat, and what it was. The pane's applet is gone.
struct ClosedPane: Equatable {
  /// Where the close falls among every close of the window, tabs included. The window issues it.
  let stamp: UInt64
  let placement: PanePlacement
  let description: AppletDescription
  let title: String

  /// The pane's exec declaration, with no environment value. A reopened pane gets it back inert,
  /// and runs nothing until the user chooses Run.
  var exec: ExecDeclaration? = nil
}

/// One window's stack of closed panes, newest last.
///
/// Reopening opens a new pane from an entry. The pane gets a new ID, since the closed pane's ID is
/// retired. The window picks the entry by stamp, because a newer close may be a tab.
struct CloseUndoLedger {
  let policy: CloseUndoPolicy

  /// Oldest first.
  private(set) var entries: [ClosedPane] = []

  init(policy: CloseUndoPolicy) {
    self.policy = policy
  }

  /// Adds a close. The oldest entries drop when the stack is deeper than the policy.
  mutating func push(_ closed: ClosedPane) {
    entries.append(closed)

    if entries.count > policy.stackDepth {
      entries.removeFirst(entries.count - policy.stackDepth)
    }
  }

  /// Removes the entry with this stamp and leaves the others where they are.
  mutating func remove(stamp: UInt64) {
    entries.removeAll { $0.stamp == stamp }
  }

  mutating func removeAll() {
    entries = []
  }
}
