import AppKit
import BrowserModel
import Theme

/// What a tab says in place of a page it could not load, when a plain notice is not enough.
///
/// The pane explains itself here because the failure leaves nothing to look at, and the one action
/// needs a place to live. The view is native, so no page's script can reach its button.
enum LoadErrorPage: Equatable {
  /// An address whose HTTPS the browser assumed could not connect, or the server did not speak
  /// TLS. `typed` is what the user typed, which Load over HTTP resolves again.
  case offerHTTP(host: String, typed: String)

  /// The server's certificate did not validate. There is no action.
  case certificate(host: String, reason: String)

  var title: String {
    switch self {
    case .offerHTTP(let host, _):
      return "Could not connect securely to \(AddressDisplay.bounded(host))"

    case .certificate(let host, _):
      return "The certificate for \(AddressDisplay.bounded(host)) is not trusted"
    }
  }

  var detail: String {
    switch self {
    case .offerHTTP:
      return
        "The browser tried HTTPS first and could not connect, or the server does not speak "
        + "HTTPS. Loading over HTTP leaves the connection unencrypted, so anyone on the network "
        + "can read and change what you send and receive."

    case .certificate(_, let reason):
      return
        "The browser did not connect, because the site could not prove who it is. Someone may "
        + "be answering for it. \(reason)"
    }
  }

  var offersHTTP: Bool {
    if case .offerHTTP = self { return true }

    return false
  }
}

/// The pane's stand-in for a page that did not load. It covers the page, shows what happened, and
/// holds the Load over HTTP button when the failure allows it.
@MainActor
final class BrowserErrorView: NSView {
  static let actionTitle = "Load over HTTP"

  let titleLabel = NSTextField(wrappingLabelWithString: "")
  let detailLabel = NSTextField(wrappingLabelWithString: "")
  let actionButton = NSButton(title: BrowserErrorView.actionTitle, target: nil, action: nil)

  var onLoadOverHTTP: () -> Void = {}

  private var palette = ThemePalette.latte

  override init(frame: NSRect) {
    super.init(frame: frame)

    wantsLayer = true
    isHidden = true

    titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
    titleLabel.alignment = .center
    titleLabel.setAccessibilityIdentifier("browser-error-title")

    detailLabel.font = .systemFont(ofSize: 13)
    detailLabel.alignment = .center
    detailLabel.setAccessibilityIdentifier("browser-error-detail")

    actionButton.bezelStyle = .rounded
    actionButton.target = self
    actionButton.action = #selector(loadOverHTTP)
    actionButton.setAccessibilityIdentifier("browser-load-over-http")
    actionButton.setAccessibilityHelp("Loads the page without encryption.")

    let stack = NSStackView(views: [titleLabel, detailLabel, actionButton])
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 12
    stack.translatesAutoresizingMaskIntoConstraints = false

    addSubview(stack)

    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: centerYAnchor),
      stack.widthAnchor.constraint(lessThanOrEqualToConstant: 460),
      stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
    ])

    setAccessibilityIdentifier("browser-error")
    setAccessibilityElement(true)
    setAccessibilityRole(.group)

    apply(palette)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not used")
  }

  func show(_ page: LoadErrorPage?) {
    guard let page else {
      isHidden = true
      setAccessibilityLabel(nil)
      return
    }

    titleLabel.stringValue = page.title
    detailLabel.stringValue = page.detail
    actionButton.isHidden = !page.offersHTTP
    setAccessibilityLabel(page.title)
    isHidden = false
  }

  func apply(_ palette: ThemePalette) {
    self.palette = palette

    layer?.backgroundColor = palette[.base].cgColor
    titleLabel.textColor = palette[.text].nsColor
    detailLabel.textColor = palette[.subtext0].nsColor
  }

  @objc private func loadOverHTTP() {
    onLoadOverHTTP()
  }
}
