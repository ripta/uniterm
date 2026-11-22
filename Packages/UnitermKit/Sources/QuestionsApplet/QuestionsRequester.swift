import Foundation

/// Who asks a form, as the host established it.
///
/// The key says which requests belong to one requester, so a requester's next form reuses its tab.
/// The name is what the header and the tab title show, exactly as the host gave it. The applet
/// never rewrites it, and a form's script never supplies it.
public struct QuestionsRequester: Equatable, Sendable {
  /// What the form's asking pane is now.
  public enum AskingPane: Equatable, Sendable {
    /// The requester has no pane to name.
    case none

    /// The pane is open. The label names it by its stable ID, such as "Pane 3".
    case open(label: String)

    /// The pane closed. Its label stays, since IDs are never reused, and the chrome says that the
    /// pane is gone. It never points at another pane.
    case gone(label: String)
  }

  public let key: String
  public let name: String
  public var askingPane: AskingPane

  public init(key: String, name: String, askingPane: AskingPane = .none) {
    self.key = key
    self.name = name
    self.askingPane = askingPane
  }

  /// The line under the requester's name, or nil when the requester has no pane.
  public var paneLine: String? {
    switch askingPane {
    case .none: return nil
    case .open(let label): return "Asked from \(label)"
    case .gone(let label): return "\(label) closed, so the pane that asked is gone"
    }
  }
}
