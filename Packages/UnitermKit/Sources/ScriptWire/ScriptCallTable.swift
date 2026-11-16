/// A power a script call needs, by the name a permission kind carries in a declaration.
///
/// It lists only the powers a call uses on its own. A host launch is checked against the layout a
/// request carries, so no call maps to it here.
public enum ScriptCallPower: String, CaseIterable, Sendable {
  case paneControl = "pane-control"
  case clipboardRead = "clipboard-read"
  case clipboardWrite = "clipboard-write"
}

/// One host call a script makes, apart from its arguments.
///
/// The call boundary in the app and the script lint both read this table, so a call's power is
/// written in one place. `ScriptCall.kind` is an exhaustive switch, so a new wire call cannot be
/// added without a row here.
public enum ScriptCallKind: CaseIterable, Sendable {
  case postStatus
  case listWindows
  case listPanes
  case openPane
  case openTab
  case send
  case sendCommand
  case requestLayout
  case readClipboard
  case writeClipboard

  /// The name of the function in the `uniterm` module, without a prefix.
  public var janetName: String {
    switch self {
    case .postStatus: return "post-status"
    case .listWindows: return "list-windows"
    case .listPanes: return "list-panes"
    case .openPane: return "open-pane"
    case .openTab: return "open-tab"
    case .send: return "send"
    case .sendCommand: return "send-command"
    case .requestLayout: return "request-layout"
    case .readClipboard: return "read-clipboard"
    case .writeClipboard: return "write-clipboard"
    }
  }

  /// The power the call needs, or nil for a call that needs none, such as posting status.
  public var power: ScriptCallPower? {
    switch self {
    case .postStatus: return nil
    case .readClipboard: return .clipboardRead
    case .writeClipboard: return .clipboardWrite
    case .listWindows, .listPanes, .openPane, .openTab, .send, .sendCommand, .requestLayout:
      return .paneControl
    }
  }

  /// The call a `uniterm` module function name stands for, or nil for a name with no wire call.
  public static func named(_ janetName: String) -> ScriptCallKind? {
    allCases.first { $0.janetName == janetName }
  }
}

extension ScriptCall {
  public var kind: ScriptCallKind {
    switch self {
    case .postStatus: return .postStatus
    case .listWindows: return .listWindows
    case .listPanes: return .listPanes
    case .openPane: return .openPane
    case .openTab: return .openTab
    case .send: return .send
    case .sendCommand: return .sendCommand
    case .requestLayout: return .requestLayout
    case .readClipboard: return .readClipboard
    case .writeClipboard: return .writeClipboard
    }
  }
}
