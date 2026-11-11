import AppletKit
import Foundation
import PaneModel

/// Who may start which exec driver in which pane. It is execution authority, a power of its own:
/// pane control, ownership, and a helper's runtime capabilities never imply it.
///
/// A launch the user asks for with Run is either covered by a grant the user made, or waits in the
/// Pending Requests panel. There the user allows it once, allows its program in its pane, or denies
/// it. Only the panel's buttons decide a request. No script call and no driver command reaches
/// this type, so a program can neither approve its own request nor ask for a launch.
///
/// Grants live for this launch of uniterm only.
@MainActor
public final class ExecLaunchAuthority {
  /// The pane a launch runs in. A pane ID is retired when the pane closes, so a grant for it can
  /// never cover a later pane.
  public struct Target: Hashable, Sendable {
    public let window: UInt64
    public let pane: NodeID
  }

  /// One launch waiting for the user. It binds the exact inputs it shows.
  public struct Request: Identifiable, Equatable, Sendable {
    public let id: UInt64
    public let target: Target
    public let paneTitle: String
    public let launch: ExecLaunch
  }

  /// What the user allowed for a pane's driver, apart from its arguments and values. A launch is
  /// covered when its program and directory are the grant's, its environment keys are among the
  /// grant's, and it runs in the grant's pane. Its arguments and its values may differ.
  public struct Grant: Identifiable, Equatable, Sendable {
    public let id: UInt64
    public let target: Target
    public let paneTitle: String
    public let executable: String
    public let directory: String
    public let environmentKeys: Set<String>

    public func covers(_ launch: ExecLaunch, in target: Target) -> Bool {
      target == self.target && launch.declaration.executable == executable
        && launch.directory == directory
        && Set(launch.declaration.environmentKeys).isSubset(of: environmentKeys)
    }
  }

  public enum Decision: Sendable, Equatable {
    /// This launch, with these exact inputs, once.
    case allowOnce

    /// This launch now, and later launches its grant covers.
    case allowInPane

    case deny
  }

  /// The most requests that wait at once. A pane holds at most one, so a repeated Run replaces its
  /// own request and never adds to the list.
  public static let maxRequests = 32

  public private(set) var requests: [Request] = []
  public private(set) var grants: [Grant] = []

  private var answers: [UInt64: @MainActor (Decision) -> Void] = [:]
  private var lastID: UInt64 = 0

  /// Runs when a request or a grant appears or goes away.
  public var onChange: (() -> Void)?

  /// Runs after every change with true while any request waits, so the pending-permissions slot
  /// shows.
  public var onActiveChanged: ((Bool) -> Void)?

  private func changed() {
    onChange?()
    onActiveChanged?(!requests.isEmpty)
  }

  public init() {}

  /// The grant that covers the launch, if any.
  public func grant(covering launch: ExecLaunch, in target: Target) -> Grant? {
    grants.first { $0.covers(launch, in: target) }
  }

  /// Puts a launch before the user. `answer` runs once, with the user's decision, or with deny
  /// when the request is replaced or its pane closes. Returns nil when the list is full, and
  /// nothing waits.
  @discardableResult
  public func request(
    _ launch: ExecLaunch, in target: Target, paneTitle: String,
    answer: @escaping @MainActor (Decision) -> Void
  ) -> UInt64? {
    withdraw(target: target)

    guard requests.count < Self.maxRequests else { return nil }

    lastID += 1

    requests.append(Request(id: lastID, target: target, paneTitle: paneTitle, launch: launch))
    answers[lastID] = answer
    changed()

    return lastID
  }

  /// The user's answer, from the Pending Requests panel.
  public func decide(_ id: UInt64, _ decision: Decision) {
    guard let index = requests.firstIndex(where: { $0.id == id }) else { return }

    let request = requests.remove(at: index)
    let answer = answers.removeValue(forKey: id)

    if decision == .allowInPane {
      lastID += 1

      grants.removeAll { $0.target == request.target }
      grants.append(
        Grant(
          id: lastID, target: request.target, paneTitle: request.paneTitle,
          executable: request.launch.declaration.executable, directory: request.launch.directory,
          environmentKeys: Set(request.launch.declaration.environmentKeys)))
    }

    changed()
    answer?(decision)
  }

  public func revokeGrant(_ id: UInt64) {
    let before = grants.count

    grants.removeAll { $0.id == id }

    if grants.count != before { changed() }
  }

  /// Withdraws a pane's waiting request, which is answered deny.
  public func withdraw(target: Target) {
    let withdrawn = requests.filter { $0.target == target }

    guard !withdrawn.isEmpty else { return }

    requests.removeAll { $0.target == target }
    changed()

    for request in withdrawn {
      answers.removeValue(forKey: request.id)?(.deny)
    }
  }

  /// A pane closed. Its request and its grant end.
  public func paneClosed(_ target: Target) {
    let hadGrant = grants.contains { $0.target == target }

    grants.removeAll { $0.target == target }
    withdraw(target: target)

    if hadGrant { changed() }
  }

  /// A window closed. Every request and grant for its panes ends.
  public func windowClosed(_ window: UInt64) {
    for target in Set(
      (requests.map(\.target) + grants.map(\.target)).filter { $0.window == window })
    {
      paneClosed(target)
    }
  }
}
