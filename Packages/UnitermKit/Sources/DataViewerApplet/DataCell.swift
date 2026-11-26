import AppKit

/// A column of the table that knows its place, so a cell finds its column without a search.
@MainActor
final class DataColumn: NSTableColumn {
  let index: Int

  init(index: Int) {
    self.index = index

    super.init(identifier: NSUserInterfaceItemIdentifier("c\(index)"))
  }

  @available(*, unavailable)
  required init(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }
}

/// One cell of the table: a single-line label whose color follows the row it sits in.
///
/// The palette colors are chosen for the pane's background. A selected row in a focused table
/// draws the system's emphasized blue under the cell, and the row view tells the cell through
/// `backgroundStyle`. The label then switches to the system's text color for that blue, and gets
/// its palette color back once the row is no longer emphasized.
@MainActor
final class DataCell: NSTableCellView {
  static let identifier = NSUserInterfaceItemIdentifier("cell")
  static let font = NSFont.systemFont(ofSize: 12)

  /// Digits of one width, so the numbers of a right-aligned column line up by place.
  static let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)

  let label = NSTextField(labelWithString: "")

  /// The label's color on the pane's own background.
  var restingColor = NSColor.labelColor {
    didSet { updateColor() }
  }

  override var backgroundStyle: NSView.BackgroundStyle {
    didSet { updateColor() }
  }

  /// The find bar's mark on the whole cell, or nil for none.
  var tint: NSColor? {
    didSet { layer?.backgroundColor = tint?.cgColor }
  }

  init() {
    super.init(frame: .zero)

    identifier = Self.identifier
    wantsLayer = true

    label.lineBreakMode = .byTruncatingTail
    label.usesSingleLineMode = true
    label.font = Self.font
    label.translatesAutoresizingMaskIntoConstraints = false
    addSubview(label)
    textField = label

    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
      label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  private func updateColor() {
    label.textColor =
      backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : restingColor
  }
}
