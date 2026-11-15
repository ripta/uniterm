import Foundation

/// Runs every closure added to it when something changes. Each observer keeps its token, and the
/// observer goes when the token does, so one observer never replaces another.
@MainActor
public final class ChangeObservers {
  public final class Token {}

  private var observers: [(token: Weak, observer: @MainActor () -> Void)] = []

  private struct Weak {
    weak var token: Token?
  }

  public init() {}

  public func add(_ observer: @escaping @MainActor () -> Void) -> Token {
    let token = Token()

    observers.append((Weak(token: token), observer))

    return token
  }

  /// Calls every observer whose token is still held, and forgets the rest.
  public func notify() {
    observers.removeAll { $0.token.token == nil }

    for entry in observers { entry.observer() }
  }
}

/// The permission questions that wait for the user, and the denials the user gave.
///
/// A program's request never opens a dialog. It waits here, and the Pending Requests panel shows
/// it while the pending-permissions slot says something waits. Requests of one power from one
/// requester share one row, however many arrive, so repeated requests cannot flood the user.
/// Each row holds at most `maxPerRow` waiting operations, one requester holds at most
/// `maxRowsPerRequester` rows, and so do all requesters that share a denial key. All requesters
/// together hold at most `maxRows`. A request past any bound is refused as busy.
///
/// Allow once releases the oldest waiting operation of a row and no other, so coalescing never
/// turns one approval into approval of several operations. The row shows that oldest operation's
/// own text, so the operation Allow once releases is always the one the user read. Allow for the
/// session answers every waiting operation of the row, and the requester remembers the power for
/// its session. Deny answers every waiting operation, and records a denial: a later request with
/// the same denial key is refused at once, with no new row, until the user chooses Ask Again.
///
/// A row's denial key is its key unless the request names a longer-lived one. A script's
/// connection asks under the connection, so its rows go when it disconnects, and denies under
/// something a reconnect keeps, so reconnecting never asks again without the user.
@MainActor
public final class PermissionRequests {
  /// Who asks. A requester's rows and denials go when it ends.
  public enum Requester: Hashable, Sendable {
    /// A script or controller connection.
    case connection(UInt64)

    /// One run of a pane's exec driver.
    case driver(window: UInt64, pane: UInt64, run: UInt64)

    /// A terminal session's programs, which an escape sequence cannot tell apart.
    case terminal(window: UInt64, pane: UInt64)

    /// The ordinary scripts that act for one pane. A script's denial is kept under it, so a
    /// reconnect does not ask again. It goes when the pane closes.
    case paneScripts(window: UInt64, pane: UInt64)

    /// Runs of one verified controller version, for a denied startup review.
    case controllerVersion(controllerID: String, version: String)
  }

  /// One requester's question about one power. `power` names the power and anything that scopes
  /// it, such as a terminal tab and its policy's generation.
  public struct Key: Hashable, Sendable {
    public let requester: Requester
    public let power: String

    public init(requester: Requester, power: String) {
      self.requester = requester
      self.power = power
    }
  }

  public enum Answer: Sendable, Equatable {
    case allowOnce
    case allowForSession
    case deny

    /// The user never answered: the requester ended, or lost the authority it asked under.
    case withdrawn
  }

  /// What came of asking.
  public enum Outcome: Sendable, Equatable {
    /// The operation waits in a row. Its answer comes later.
    case waiting

    /// The user denied this key and has not asked to be asked again. The answer is never called.
    case denied

    /// Too many operations or rows wait. The answer is never called.
    case busy
  }

  public struct Row: Identifiable, Equatable, Sendable {
    public let id: UInt64
    public let key: Key

    /// What asks, such as a script's name and PID.
    public let subject: String

    /// What it asks for, such as "Read the clipboard".
    public let title: String

    /// The text of the oldest waiting operation, the one Allow once releases next. The panel
    /// shows it in full.
    public internal(set) var detail: String

    /// What a denial of this row is recorded under.
    public let denialKey: Key

    /// The label of the session answer, which says what it covers.
    public let sessionTitle: String

    /// How many operations wait in the row.
    public var waiting: Int
  }

  public struct Denial: Identifiable, Equatable, Sendable {
    public let id: UInt64
    public let key: Key
    public let subject: String
    public let title: String
  }

  public static let maxRows = 64
  public static let maxRowsPerRequester = 16
  public static let maxPerRow = 8

  public private(set) var rows: [Row] = []
  public private(set) var denials: [Denial] = []

  /// One waiting operation: its own text, and the call that answers it.
  private struct Operation {
    let detail: String
    let answer: @MainActor (Answer) -> Void
  }

  /// Each row's waiting operations, oldest first.
  private var operations: [UInt64: [Operation]] = [:]
  private var lastID: UInt64 = 0

  public let changes = ChangeObservers()

  public init() {}

  /// True while any row waits, so the pending-permissions slot shows.
  public var isWaiting: Bool { !rows.isEmpty }

  public func isDenied(_ key: Key) -> Bool {
    denials.contains { $0.key == key }
  }

  /// Puts an operation before the user. A request whose key already has a row joins it, and the
  /// row keeps showing its oldest operation. `denialKey` names what a denial covers, when that
  /// should outlive the requester that asks.
  public func ask(
    _ key: Key, deniedAs denialKey: Key? = nil, subject: String, title: String, detail: String,
    sessionTitle: String, answer: @escaping @MainActor (Answer) -> Void
  ) -> Outcome {
    let denialKey = denialKey ?? key

    if isDenied(key) || isDenied(denialKey) { return .denied }

    let operation = Operation(detail: detail, answer: answer)

    if let index = rows.firstIndex(where: { $0.key == key }) {
      guard rows[index].waiting < Self.maxPerRow else { return .busy }

      rows[index].waiting += 1
      operations[rows[index].id, default: []].append(operation)
      changes.notify()

      return .waiting
    }

    // A program that opens many connections asks under each, but they share its denial key, so
    // both count against the bound.
    guard rows.count < Self.maxRows,
      rows.count(where: { $0.key.requester == key.requester }) < Self.maxRowsPerRequester,
      rows.count(where: { $0.denialKey.requester == denialKey.requester })
        < Self.maxRowsPerRequester
    else { return .busy }

    lastID += 1
    rows.append(
      Row(
        id: lastID, key: key, subject: subject, title: title, detail: detail,
        denialKey: denialKey, sessionTitle: sessionTitle, waiting: 1))
    operations[lastID] = [operation]
    changes.notify()

    return .waiting
  }

  /// The user's answer to a row, from the Pending Requests panel only.
  public func decide(_ id: UInt64, _ answer: Answer) {
    guard answer != .withdrawn, let index = rows.firstIndex(where: { $0.id == id }) else { return }

    let row = rows[index]
    var waiting = operations[id] ?? []
    let answered: [Operation]

    if answer == .allowOnce {
      answered = waiting.isEmpty ? [] : [waiting.removeFirst()]
    } else {
      answered = waiting
      waiting = []
    }

    if let next = waiting.first {
      rows[index].waiting = waiting.count
      rows[index].detail = next.detail
      operations[id] = waiting
    } else {
      rows.remove(at: index)
      operations[id] = nil
    }

    if answer == .deny { recordDenial(row.denialKey, subject: row.subject, title: row.title) }

    changes.notify()

    for operation in answered { operation.answer(answer) }
  }

  /// Records a denial with no row, such as a refused startup review.
  ///
  /// Denials have no count bound, and none is ever dropped to make room. Each one is a user's Deny.
  /// No program can grow the list. Dropping a denial would ask its program again on its own.
  public func recordDenial(_ key: Key, subject: String, title: String) {
    guard !isDenied(key) else { return }

    lastID += 1
    denials.append(Denial(id: lastID, key: key, subject: subject, title: title))

    changes.notify()
  }

  /// The user's local retry. The next request with the denial's key asks again.
  public func askAgain(_ id: UInt64) {
    let before = denials.count

    denials.removeAll { $0.id == id }

    if denials.count != before { changes.notify() }
  }

  /// The requesters that match no longer exist, or lost the authority they asked under. Their
  /// waiting operations are answered as withdrawn, with no denial recorded, and their denials go.
  public func end(where ends: (Requester) -> Bool) {
    let ended = rows.filter { ends($0.key.requester) }
    let hadDenials = denials.contains { ends($0.key.requester) }

    guard !ended.isEmpty || hadDenials else { return }

    rows.removeAll { ends($0.key.requester) }
    denials.removeAll { ends($0.key.requester) }

    let replies = ended.flatMap { operations.removeValue(forKey: $0.id) ?? [] }

    changes.notify()

    for operation in replies { operation.answer(.withdrawn) }
  }

  public func end(_ requester: Requester) {
    end { $0 == requester }
  }
}
