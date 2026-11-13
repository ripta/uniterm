import AppletKit
import StatusKit

/// Names a slot of the status bar. The window owns its slots. The focused pane's applet fills the
/// applet slots. A later slot joins as a new case.
enum BarSegmentID: Hashable, Sendable {
  case message
  case dismiss
  case unseenError
  case unseenWarning
  case window(WindowStateKind)
  case applet(Int)

  var identifier: String {
    switch self {
    case .message: return "status-message"
    case .dismiss: return "status-dismiss"
    case .unseenError: return "status-unseen-error"
    case .unseenWarning: return "status-unseen-warning"
    case .window(let kind): return "status-window-\(kind.identifier)"
    case .applet(let index): return "status-applet-\(index)"
    }
  }
}

/// How a segment is colored and weighted. The bar maps a tone to a theme token.
enum BarTone: Sendable, Equatable {
  case normal
  case emphasized
  case warning
  case error
}

/// One slot of the status bar: a small icon, one line of text, or both.
struct BarSegment: Sendable, Equatable {
  var id: BarSegmentID
  var symbolName: String?
  var text: String?
  var tone: BarTone
  var accessibilityLabel: String?

  /// The full sentence a compact segment shows on hover. Nil for a segment whose text is complete.
  var toolTip: String?

  init(
    id: BarSegmentID, symbolName: String?, text: String?, tone: BarTone,
    accessibilityLabel: String? = nil, toolTip: String? = nil
  ) {
    self.id = id
    self.symbolName = symbolName
    self.text = text
    self.tone = tone
    self.accessibilityLabel = accessibilityLabel
    self.toolTip = toolTip
  }
}

/// Works out what the status bar shows. It is pure, so a test needs no window.
enum StatusBarContent {
  /// The window's slots in order: the message area, a dismiss control while an error is on the
  /// bar, one unseen indicator, one slot for each active window state, then the
  /// focused applet's slots. The message area is always there, empty when the bar is idle, so the
  /// layout does not jump when a message arrives.
  static func segments(
    display: StatusDisplay?, hasUnseenError: Bool, hasUnseenWarning: Bool = false,
    windowStates: WindowStates = WindowStates(), applet: [AppletSegment]
  ) -> [BarSegment] {
    var result = [message(display)]

    if display?.message.level == .error {
      result.append(
        BarSegment(
          id: .dismiss, symbolName: "xmark.circle", text: nil, tone: .normal,
          accessibilityLabel: "Dismiss message", toolTip: "Dismiss message"))
    }

    if hasUnseenError {
      result.append(
        BarSegment(
          id: .unseenError, symbolName: "exclamationmark.circle.fill", text: nil, tone: .error,
          accessibilityLabel: "Unseen errors", toolTip: "Unseen errors"))
    } else if hasUnseenWarning {
      result.append(
        BarSegment(
          id: .unseenWarning, symbolName: "exclamationmark.triangle.fill", text: nil,
          tone: .warning, accessibilityLabel: "Unseen warnings", toolTip: "Unseen warnings"))
    }

    for state in windowStates.active {
      result.append(
        BarSegment(
          id: .window(state.kind), symbolName: state.kind.symbolName, text: state.label,
          tone: .warning,
          accessibilityLabel: state.text, toolTip: state.text))
    }

    for (index, segment) in applet.enumerated() {
      result.append(
        BarSegment(
          id: .applet(index), symbolName: segment.symbolName, text: segment.text,
          tone: tone(for: segment.style), accessibilityLabel: nil))
    }

    return result
  }

  static func message(_ display: StatusDisplay?) -> BarSegment {
    guard let display else {
      return BarSegment(id: .message, symbolName: nil, text: "", tone: .normal)
    }

    var text =
      "\(sourceLabel(display.message.source, includesPaneID: false)): \(display.message.text)"
    if display.collapsedErrors > 0 {
      text += "  (+\(display.collapsedErrors) more errors)"
    }

    return BarSegment(
      id: .message, symbolName: symbol(for: display.message.level), text: text,
      tone: tone(for: display.message.level), accessibilityLabel: nil)
  }

  /// One line of the history: the level, the source, and the text.
  static func historyLine(_ message: StatusMessage) -> String {
    "\(name(of: message.level))  \(sourceLabel(message.source)): \(message.text)"
  }

  /// A source as the bar and the history name it. Only the host reads as plain `uniterm`. An
  /// applet or script shows its kind and issued ID after its name, so one that calls itself
  /// `uniterm` cannot pass for the host, and two with one name stay apart. The history adds a
  /// pane's stable ID to its title, since two panes can share a title.
  static func sourceLabel(_ source: StatusSource, includesPaneID: Bool = true) -> String {
    switch source {
    case .pane(let id, let name): return includesPaneID ? "\(name) (pane \(id))" : name
    case .applet(let id, let name): return "\(name) (applet \(id))"
    case .script(let id, let name): return "\(name) (script \(id))"
    case .uniterm: return "uniterm"
    }
  }

  static func name(of level: StatusLevel) -> String {
    switch level {
    case .info: return "info"
    case .warning: return "warning"
    case .error: return "error"
    }
  }

  static func symbol(for level: StatusLevel) -> String {
    switch level {
    case .info: return "info.circle"
    case .warning: return "exclamationmark.triangle"
    case .error: return "xmark.octagon"
    }
  }

  static func tone(for level: StatusLevel) -> BarTone {
    switch level {
    case .info: return .normal
    case .warning: return .warning
    case .error: return .error
    }
  }

  static func tone(for style: AppletSegment.Style) -> BarTone {
    switch style {
    case .normal: return .normal
    case .emphasized: return .emphasized
    case .warning: return .warning
    case .error: return .error
    }
  }
}
