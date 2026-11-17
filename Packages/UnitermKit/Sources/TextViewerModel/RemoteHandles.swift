import AppletKit
import Foundation

/// Why a load, a scroll, or a find did not finish. A code is a fixed word. It never carries a file
/// name, a path, or any text of the document, since the reply that holds it crosses to a program.
public enum RemoteFailure: String, Sendable, Equatable, CaseIterable {
  /// The file could not be found, opened, or read.
  case unreadable

  /// The file or the content is past a cap.
  case tooLarge = "too-large"

  /// The file is not a format the viewer shows, or is locked.
  case unsupported

  /// The document reader or the page could not turn the content into a view.
  case renderFailed = "render-failed"

  /// The Markdown page could not start.
  case viewerUnavailable = "viewer-unavailable"

  /// WebKit's content process ended while the page showed the content.
  case processEnded = "process-ended"
}

/// What a scroll or a find reports when it finishes. A field is nil when the command has no such
/// answer. None of it is document text.
public struct RemoteLanding: Equatable, Sendable {
  public var count: Int?
  public var capped: Bool?

  /// The match shown now, counted from zero.
  public var current: Int?
  public var anchor: TextViewerAnchor?

  public init(
    count: Int? = nil, capped: Bool? = nil, current: Int? = nil, anchor: TextViewerAnchor? = nil
  ) {
    self.count = count
    self.capped = capped
    self.current = current
    self.anchor = anchor
  }
}

/// How one command's effect ended.
public enum RemoteOutcome: Equatable, Sendable {
  case loaded
  case done(RemoteLanding)
  case failed(RemoteFailure)

  /// A newer command or load took the place of this one before it finished.
  case superseded
}

/// The results a pane keeps for the commands that changed it.
///
/// A command with an effect answers at once with a handle, and the result waits under that handle
/// for the `wait` command. The table is small and holds the newest results. When it is full, the
/// oldest finished one is dropped. A handle still running is never dropped, so a command is refused
/// before it starts when the table has no room.
public struct RemoteHandleTable: Sendable, Equatable {
  public enum Kind: String, Sendable, Equatable {
    case load, scroll, find
  }

  public struct Entry: Sendable, Equatable {
    public let id: Int
    public let kind: Kind
    public var outcome: RemoteOutcome?

    public var isSettled: Bool { outcome != nil }
  }

  public static let capacity = 32

  public private(set) var entries: [Entry] = []

  /// The handle of the load that is running now, if a command started it.
  public private(set) var activeLoad: Int?

  private var nextID = 1

  public init() {}

  /// True when a new handle can be made, since there is a free slot or a finished entry to drop.
  public var hasRoom: Bool {
    entries.count < Self.capacity || entries.contains { $0.isSettled }
  }

  /// Makes a handle. Returns nil when the table is full of handles still running.
  public mutating func open(_ kind: Kind) -> Int? {
    if entries.count >= Self.capacity {
      guard let oldest = entries.firstIndex(where: { $0.isSettled }) else { return nil }

      entries.remove(at: oldest)
    }

    let id = nextID

    nextID += 1
    entries.append(Entry(id: id, kind: kind, outcome: nil))

    if kind == .load { activeLoad = id }

    return id
  }

  public func entry(_ id: Int) -> Entry? {
    entries.first { $0.id == id }
  }

  /// Records how a handle ended. Returns false when the handle is unknown or already ended.
  @discardableResult
  public mutating func settle(_ id: Int, _ outcome: RemoteOutcome) -> Bool {
    guard let index = entries.firstIndex(where: { $0.id == id }), !entries[index].isSettled
    else { return false }

    entries[index].outcome = outcome

    if activeLoad == id { activeLoad = nil }

    return true
  }

  /// Every handle still running.
  public var running: [Int] {
    entries.filter { !$0.isSettled }.map(\.id)
  }

  /// What `wait` answers for a handle. A handle still running answers `pending`.
  ///
  /// A reply for a caller that may not see the pane's file carries no detail from it. A finished
  /// find or scroll answers `done` with nothing else, and every failure answers `unreadable`, so
  /// the caller cannot tell a missing file from a large one or a locked one.
  public static func reply(for entry: Entry, redacted: Bool = false) -> JSONValue {
    var fields: [String: JSONValue] = [:]

    switch entry.outcome {
    case nil:
      fields["state"] = .string("pending")

    case .loaded?:
      fields["state"] = .string("loaded")

    case .superseded?:
      fields["state"] = .string("superseded")

    case .failed(let failure)?:
      fields["state"] = .string("failed")
      fields["code"] = .string(redacted ? RemoteFailure.unreadable.rawValue : failure.rawValue)

    case .done(let landing)?:
      fields["state"] = .string("done")

      if redacted { break }

      if let count = landing.count { fields["count"] = .number(Double(count)) }

      if let capped = landing.capped { fields["capped"] = .bool(capped) }

      if let current = landing.current { fields["current"] = .number(Double(current)) }

      if let anchor = landing.anchor, let value = RemoteAnchor.json(of: anchor) {
        fields["anchor"] = value
      }
    }

    return .object(fields)
  }

  /// The reply of a handle that is still running, for a wait that ran out of time.
  public static let pendingReply: JSONValue = .object(["state": .string("pending")])
}
