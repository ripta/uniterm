import Foundation

/// How serious a status message is. The level sets its style. Messages carry no priority.
public enum StatusLevel: Int, Sendable, Comparable {
  case info
  case warning
  case error

  public static func < (lhs: StatusLevel, rhs: StatusLevel) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

/// Who posted a message. The bar and the history show it, so an untrusted program cannot pass its
/// text off as uniterm's own.
///
/// The name is a label that may change. Identity lives in `key`. A pane's key is its stable pane
/// ID. The key of an applet or script is an ID the status center issued to that producer, and it
/// is never reused. `uniterm` is the host itself.
public enum StatusSource: Sendable, Equatable {
  case pane(id: UInt64, name: String)
  case applet(id: UInt64, name: String)
  case script(id: UInt64, name: String)
  case uniterm

  public var label: String {
    switch self {
    case .pane(_, let name): return name
    case .applet(_, let name): return name
    case .script(_, let name): return name
    case .uniterm: return "uniterm"
    }
  }

  /// The pane that posted, or nil for any other source.
  public var paneID: UInt64? {
    guard case .pane(let id, _) = self else { return nil }

    return id
  }

  /// The identity without its label. Coalescing, retention, and filtering compare keys.
  public var key: StatusSourceKey {
    switch self {
    case .pane(let id, _): return .pane(id)
    case .applet(let id, _): return .applet(id)
    case .script(let id, _): return .script(id)
    case .uniterm: return .uniterm
    }
  }

  /// The same source with its label cut to `maximumBytes`.
  func boundingLabel(to maximumBytes: Int) -> StatusSource {
    switch self {
    case .pane(let id, let name):
      return .pane(id: id, name: StatusText.bounded(name, maximumBytes: maximumBytes))

    case .applet(let id, let name):
      return .applet(id: id, name: StatusText.bounded(name, maximumBytes: maximumBytes))

    case .script(let id, let name):
      return .script(id: id, name: StatusText.bounded(name, maximumBytes: maximumBytes))

    case .uniterm:
      return self
    }
  }
}

/// A source's identity, apart from its label.
public enum StatusSourceKey: Sendable, Hashable {
  case pane(UInt64)
  case applet(UInt64)
  case script(UInt64)
  case uniterm
}

public struct StatusMessage: Sendable, Equatable, Identifiable {
  public let id: UInt64
  public let level: StatusLevel
  public let source: StatusSource
  public let text: String

  /// Seconds on the queue's clock.
  public let postedAt: TimeInterval

  /// What the message costs to keep: its text, its label, and a fixed share for the record.
  var storageBytes: Int {
    text.utf8.count + source.label.utf8.count + StatusPolicy.recordOverheadBytes
  }
}

/// A message on the bar, with the count of older errors folded into it.
public struct StatusDisplay: Sendable, Equatable {
  public let message: StatusMessage
  public let collapsedErrors: Int
}

/// A pane that has rows in the history. The name is the title the pane had at its newest row.
public struct HistoryPane: Sendable, Equatable, Identifiable {
  public let id: UInt64
  public let name: String
}

/// What retention has dropped. The history shows it as one summary, so a loss is never silent.
///
/// Dropping a record never acknowledges it. The unseen counts carry over until the user
/// acknowledges the summary.
public struct RetentionLoss: Sendable, Equatable {
  public var errors = 0
  public var others = 0
  public var unseenErrors = 0
  public var unseenWarnings = 0

  public init() {}

  public var isEmpty: Bool { errors == 0 && others == 0 }

  public var text: String {
    var parts: [String] = []

    if errors > 0 {
      parts.append(errors == 1 ? "1 error" : "\(errors) errors")
    }

    if others > 0 {
      parts.append(others == 1 ? "1 other message" : "\(others) other messages")
    }

    let dropped = parts.joined(separator: " and ")
    var result = "The history dropped \(dropped) to stay within its limits."

    if unseenErrors > 0 || unseenWarnings > 0 {
      var unseen: [String] = []

      if unseenErrors > 0 {
        unseen.append(unseenErrors == 1 ? "1 unseen error" : "\(unseenErrors) unseen errors")
      }

      if unseenWarnings > 0 {
        unseen.append(
          unseenWarnings == 1 ? "1 unseen warning" : "\(unseenWarnings) unseen warnings")
      }

      result += " It held " + unseen.joined(separator: " and ") + "."
    }

    return result
  }
}

/// The bounds that shape the queue. A caller changes them only in tests.
///
/// The byte limits size each store for its worst case. Real messages run well under 200 bytes, so
/// the count limits bind first. The byte limits stop a source of long text from holding a window's
/// memory. At the limits one window keeps under 400 KiB of history, 64 KiB of waiting messages, and
/// 128 KiB of folded errors.
public struct StatusPolicy: Sendable, Equatable {
  /// A fixed cost added to each record, for the value itself and the indexes that point at it.
  static let recordOverheadBytes = 64

  /// How long a message stays before the next queued one may replace it.
  public var minimumDwell: TimeInterval = 1.5

  /// How long an info or warning message stays once the queue is empty.
  public var idleTimeout: TimeInterval = 5

  /// The pending count above which the bar skips to the newest message.
  public var backlogLimit = 3

  /// The most error records the history keeps.
  public var errorHistoryLimit = 100

  /// The most info and warning records the history keeps.
  public var otherHistoryLimit = 400

  /// The most bytes the error pool keeps. 100 errors of about 1.3 KiB.
  public var errorHistoryBytes = 128 * 1024

  /// The most bytes the info and warning pool keeps. 400 messages of about 650 bytes.
  public var otherHistoryBytes = 256 * 1024

  /// The most bytes of text one message keeps. A longer text is cut with an ellipsis.
  public var maximumTextBytes = 2048

  /// The most bytes a source label keeps.
  public var maximumLabelBytes = 128

  /// The most messages waiting for a turn on the bar, and their bytes. Past either, the backlog
  /// folds at once instead of at the next turn.
  public var pendingLimit = 32
  public var pendingBytes = 64 * 1024

  /// The most errors folded into the one on the bar, and their bytes. Older ones leave the fold
  /// and stay counted. They are still in the history while retention keeps them.
  public var foldedLimit = 100
  public var foldedBytes = 128 * 1024

  /// The most producers the center issues identities to at once.
  public var producerLimit = 64

  public static let standard = StatusPolicy()

  public init() {}

  /// The most records the history keeps.
  public var historyLimit: Int { errorHistoryLimit + otherHistoryLimit }
}
