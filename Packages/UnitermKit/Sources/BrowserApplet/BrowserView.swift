import AppKit
import Theme
import WebKit

/// The browser pane's own view: a toolbar with back, forward, and reload buttons and an address
/// bar, above the page.
///
/// The view holds no browsing state. The applet tells it what to show, and it reports what the user
/// did.
@MainActor
final class BrowserView: NSView, NSTextFieldDelegate {
  let backButton = BrowserView.makeButton(
    symbol: "chevron.left", label: "Back", identifier: "browser-back")
  let forwardButton = BrowserView.makeButton(
    symbol: "chevron.right", label: "Forward", identifier: "browser-forward")
  let reloadButton = BrowserView.makeButton(
    symbol: "arrow.clockwise", label: "Reload", identifier: "browser-reload")
  let addressField = NSTextField()

  var onBack: () -> Void = {}
  var onForward: () -> Void = {}
  var onReload: () -> Void = {}

  /// The user pressed Return in the address bar with this text.
  var onSubmit: (String) -> Void = { _ in }

  private let toolbar = NSStackView()
  private var page: NSView?
  private var palette = ThemePalette.latte
  private(set) var addressIsInvalid = false

  /// What the address bar shows when the user is not editing it.
  private var shownAddress = ""

  override init(frame: NSRect) {
    super.init(frame: frame)

    wantsLayer = true

    addressField.placeholderString = "Enter address"
    addressField.bezelStyle = .roundedBezel
    addressField.lineBreakMode = .byTruncatingTail
    addressField.usesSingleLineMode = true
    addressField.delegate = self
    addressField.setAccessibilityIdentifier("browser-address")
    addressField.setAccessibilityLabel("Address")
    addressField.setContentHuggingPriority(.defaultLow, for: .horizontal)

    backButton.target = self
    backButton.action = #selector(back)
    forwardButton.target = self
    forwardButton.action = #selector(forward)
    reloadButton.target = self
    reloadButton.action = #selector(reload)

    toolbar.orientation = .horizontal
    toolbar.spacing = 6
    toolbar.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
    toolbar.setViews([backButton, forwardButton, reloadButton, addressField], in: .leading)
    toolbar.translatesAutoresizingMaskIntoConstraints = false

    addSubview(toolbar)

    NSLayoutConstraint.activate([
      toolbar.topAnchor.constraint(equalTo: topAnchor),
      toolbar.leadingAnchor.constraint(equalTo: leadingAnchor),
      toolbar.trailingAnchor.constraint(equalTo: trailingAnchor),
    ])

    setAccessibilityIdentifier("browser")
    setAccessibilityElement(true)
    setAccessibilityRole(.group)

    apply(palette)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not used")
  }

  /// Puts `webView` below the toolbar.
  func show(page webView: NSView) {
    page?.removeFromSuperview()
    page = webView

    webView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(webView)

    NSLayoutConstraint.activate([
      webView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
      webView.leadingAnchor.constraint(equalTo: leadingAnchor),
      webView.trailingAnchor.constraint(equalTo: trailingAnchor),
      webView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  func show(canGoBack: Bool, canGoForward: Bool, isLoading: Bool) {
    backButton.isEnabled = canGoBack
    forwardButton.isEnabled = canGoForward

    reloadButton.toolTip = isLoading ? "Reload, loading" : "Reload"
  }

  /// Shows `address` unless the user is typing in the bar. A page that finishes loading while the
  /// user edits must not overwrite the edit.
  func show(address: String) {
    shownAddress = address

    guard !isEditingAddress else { return }

    addressField.stringValue = address
  }

  func focusAddress() {
    window?.makeFirstResponder(addressField)
    addressField.selectText(nil)
  }

  /// Marks the typed text as an address the browser refused. Any edit clears the mark.
  func markAddress(invalid: Bool) {
    addressIsInvalid = invalid

    addressField.textColor = invalid ? palette[.red].nsColor : palette[.text].nsColor
    addressField.setAccessibilityHelp(invalid ? "This address cannot be loaded." : nil)
  }

  func apply(_ palette: ThemePalette) {
    self.palette = palette

    appearance = NSAppearance(named: palette.flavor.isDark ? .darkAqua : .aqua)
    layer?.backgroundColor = palette[.base].cgColor
    addressField.textColor = addressIsInvalid ? palette[.red].nsColor : palette[.text].nsColor
  }

  var isEditingAddress: Bool {
    guard let editor = addressField.currentEditor() else { return false }

    return window?.firstResponder === editor
  }

  // MARK: Actions

  @objc private func back() { onBack() }
  @objc private func forward() { onForward() }
  @objc private func reload() { onReload() }

  func control(
    _ control: NSControl, textView: NSTextView, doCommandBy selector: Selector
  ) -> Bool {
    switch selector {
    case #selector(NSResponder.insertNewline(_:)):
      onSubmit(addressField.stringValue)
      return true

    case #selector(NSResponder.cancelOperation(_:)):
      addressField.stringValue = shownAddress
      markAddress(invalid: false)
      window?.makeFirstResponder(page)
      return true

    default:
      return false
    }
  }

  func controlTextDidChange(_ notification: Notification) {
    if addressIsInvalid { markAddress(invalid: false) }
  }

  private static func makeButton(symbol: String, label: String, identifier: String) -> NSButton {
    let button = NSButton(
      image: NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage(),
      target: nil, action: nil)

    button.bezelStyle = .texturedRounded
    button.isBordered = false
    button.toolTip = label
    button.setAccessibilityLabel(label)
    button.setAccessibilityIdentifier(identifier)
    button.refusesFirstResponder = true

    return button
  }
}
