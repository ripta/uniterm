import AppKit
import WebKit

/// The browser's web view. It turns the mouse's back and forward buttons into history steps, which
/// WebKit's own view ignores.
@MainActor
final class BrowserWebView: WKWebView {
  enum HistoryButton: Equatable {
    case back
    case forward
  }

  var onHistoryButton: ((HistoryButton) -> Void)?

  /// The mouse buttons numbered 4 and 5 have button numbers 3 and 4, counting from 0.
  static func historyButton(forButtonNumber number: Int) -> HistoryButton? {
    switch number {
    case 3: return .back
    case 4: return .forward
    default: return nil
    }
  }

  override func otherMouseDown(with event: NSEvent) {
    guard Self.historyButton(forButtonNumber: event.buttonNumber) == nil else { return }

    super.otherMouseDown(with: event)
  }

  override func otherMouseUp(with event: NSEvent) {
    guard let button = Self.historyButton(forButtonNumber: event.buttonNumber) else {
      super.otherMouseUp(with: event)
      return
    }

    onHistoryButton?(button)
  }
}
