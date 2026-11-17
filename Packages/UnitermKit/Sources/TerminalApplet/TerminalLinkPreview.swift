import AppKit
import Theme

/// Shows where a link under the pointer goes. It sits at the bottom left of the terminal, as
/// Ghostty's own app shows a link's address, and it never takes a click.
///
/// The text is the target the click would open, never the link's own text. It shows a path whole
/// when the pane is wide enough, and cuts the middle when it is not. Showing it touches no file.
@MainActor
final class TerminalLinkPreview: NSView {
  /// The label's accessibility identifier. A UI test reads the target from it.
  static let labelIdentifier = "terminal-link-preview"

  private static let margin: CGFloat = 8
  private static let padding = NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 8)

  private let label = NSTextField(labelWithString: "")
  private var palette: ThemePalette = .latte

  override var isFlipped: Bool { true }

  /// The text shown, or nil while nothing is.
  var text: String? {
    didSet {
      label.stringValue = text ?? ""
      isHidden = text == nil
      needsLayout = true
    }
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)

    wantsLayer = true
    layer?.cornerRadius = 4
    layer?.borderWidth = 1

    label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    label.lineBreakMode = .byTruncatingMiddle
    label.maximumNumberOfLines = 1
    label.setAccessibilityIdentifier(Self.labelIdentifier)
    addSubview(label)

    isHidden = true
    apply(palette)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  /// Lets every click through to the terminal below.
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  func apply(_ palette: ThemePalette) {
    self.palette = palette
    layer?.backgroundColor = palette[.mantle].cgColor
    layer?.borderColor = palette[.overlay0].cgColor
    label.textColor = palette[.text].nsColor
  }

  /// Puts the preview at the bottom left of the area, no wider than the area.
  func place(in area: NSRect) {
    guard !isHidden else { return }

    // What the cell needs to draw the text without cutting it. The cell adds its own insets, so
    // neither the intrinsic size nor the bare string width is enough.
    let needed =
      label.cell?.cellSize(
        forBounds: NSRect(x: 0, y: 0, width: CGFloat.greatestFiniteMagnitude, height: 100))
      ?? label.intrinsicContentSize
    let natural = NSSize(width: ceil(needed.width), height: ceil(needed.height))
    let widest = max(0, area.width - 2 * Self.margin)
    let width = min(natural.width + Self.padding.left + Self.padding.right, widest)
    let height = natural.height + Self.padding.top + Self.padding.bottom

    frame = NSRect(
      x: area.minX + Self.margin, y: area.maxY - Self.margin - height, width: width, height: height)
    label.frame = NSRect(
      x: Self.padding.left, y: Self.padding.top,
      width: max(0, width - Self.padding.left - Self.padding.right), height: natural.height)
  }
}
