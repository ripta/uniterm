import AppKit
import WebKit

/// The context menu's new-window items, which the browser turns into new-tab items.
///
/// WebKit builds the menu, and its items carry fixed identifiers. The rewrite keys on the
/// identifier, never on the title, since a title follows the user's language. The items keep
/// WebKit's action, which asks for a new window, and the tab's UI delegate answers that with a tab,
/// so a link opened from the menu goes through the same scheme gate as any new window. Each
/// rewritten item first tells the web view that the user chose it, since a choice from a menu is the
/// user's own act, and no script can make one.
enum NewTabMenu {
  static let titles: [String: String] = [
    "WKMenuItemIdentifierOpenLinkInNewWindow": "Open Link in New Tab",
    "WKMenuItemIdentifierOpenImageInNewWindow": "Open Image in New Tab",
    "WKMenuItemIdentifierOpenFrameInNewWindow": "Open Frame in New Tab",
    "WKMenuItemIdentifierOpenMediaInNewWindow": "Open Media in New Tab",
  ]

  /// Stands between a rewritten item and WebKit's action. The menu holds an item's target
  /// weakly, so the web view keeps the forwarders for as long as the menu can be open.
  @MainActor
  final class Forwarder: NSObject {
    private weak var target: AnyObject?
    private let action: Selector?
    private let onChoose: @MainActor () -> Void

    init(target: AnyObject?, action: Selector?, onChoose: @escaping @MainActor () -> Void) {
      self.target = target
      self.action = action
      self.onChoose = onChoose
    }

    @objc func forward(_ sender: Any?) {
      onChoose()

      guard let action else { return }

      NSApplication.shared.sendAction(action, to: target, from: sender)
    }
  }

  /// Retitles the new-window items and routes each through a forwarder. The forwarders come back
  /// for the caller to keep.
  @MainActor
  static func rewrite(_ menu: NSMenu, onChoose: @escaping @MainActor () -> Void) -> [Forwarder] {
    var forwarders: [Forwarder] = []

    for item in menu.items {
      guard let identifier = item.identifier?.rawValue, let title = titles[identifier] else {
        continue
      }

      let forwarder = Forwarder(target: item.target, action: item.action, onChoose: onChoose)

      item.title = title
      item.target = forwarder
      item.action = #selector(Forwarder.forward(_:))

      forwarders.append(forwarder)
    }

    return forwarders
  }
}

/// The browser's web view. It turns the mouse's back and forward buttons into history steps, which
/// WebKit's own view ignores.
@MainActor
final class BrowserWebView: WKWebView {
  enum HistoryButton: Equatable {
    case back
    case forward
  }

  var onHistoryButton: ((HistoryButton) -> Void)?

  /// The user chose a new-tab item in the context menu.
  var onMenuChoice: (() -> Void)?

  private var forwarders: [NewTabMenu.Forwarder] = []

  /// How many times the history record was read. A read costs time in step with the history, so a
  /// test counts them to show that a page's title changes read none.
  private(set) var interactionStateReads = 0

  override var interactionState: Any? {
    get {
      interactionStateReads += 1

      return super.interactionState
    }
    set { super.interactionState = newValue }
  }

  /// A real left mouse-up reached the view. Only the view sees one, so this is how the tab tells a
  /// link the user clicked from a link a script clicked.
  var onMouseUp: (() -> Void)?

  /// The mouse buttons numbered 4 and 5 have button numbers 3 and 4, counting from 0.
  static func historyButton(forButtonNumber number: Int) -> HistoryButton? {
    switch number {
    case 3: return .back
    case 4: return .forward
    default: return nil
    }
  }

  override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
    super.willOpenMenu(menu, with: event)

    forwarders = NewTabMenu.rewrite(menu) { [weak self] in self?.onMenuChoice?() }
  }

  override func mouseUp(with event: NSEvent) {
    onMouseUp?()

    super.mouseUp(with: event)
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
