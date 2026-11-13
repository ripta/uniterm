import Foundation

/// The clipboard as the typed clipboard requests reach it. The app supplies the general
/// pasteboard, and tests supply a clipboard of their own, so no test touches the user's.
///
/// A caller reaches it only after it has checked the requester's live grant for that exact
/// operation, so these calls are the access boundary.
@MainActor
public protocol ScriptClipboard: AnyObject {
  /// The clipboard's plain text, or nil when it holds none. Another app may supply the text only
  /// when asked, so a read can wait on that app. The read is async, and the general pasteboard is
  /// read off the main actor.
  func readText() async -> String?

  func writeText(_ text: String)
}

/// A clipboard held in memory.
@MainActor
public final class MemoryClipboard: ScriptClipboard {
  public var text: String?

  /// How many times each call reached the clipboard.
  public private(set) var reads = 0
  public private(set) var writes = 0

  public init(text: String? = nil) {
    self.text = text
  }

  public func readText() async -> String? {
    reads += 1

    return text
  }

  public func writeText(_ text: String) {
    writes += 1
    self.text = text
  }
}
