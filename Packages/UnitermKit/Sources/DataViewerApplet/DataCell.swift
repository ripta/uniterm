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
///
/// A find match tints the whole cell, and the tint covers the blue. So a tinted cell keeps the ink
/// chosen for its tint whatever the row's style.
@MainActor
final class DataCell: NSTableCellView {
  static let identifier = NSUserInterfaceItemIdentifier("cell")
  static let font = NSFont.systemFont(ofSize: 12)

  /// Digits of one width, so the numbers of a right-aligned column line up by place.
  static let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)

  /// How far below the baseline the filter's underline sits, and how thick it is.
  static let underlineOffset: CGFloat = 2
  static let underlineThickness: CGFloat = 2

  let label = DataCellLabel(labelWithString: "")

  /// The label's color on the pane's own background.
  var restingColor = NSColor.labelColor {
    didSet { updateColor() }
  }

  override var backgroundStyle: NSView.BackgroundStyle {
    didSet { updateColor() }
  }

  /// The find bar's mark on the whole cell, or nil for none.
  private(set) var tint: NSColor?

  /// The text color on the tint.
  private(set) var tintInk: NSColor?

  /// Marks the cell with a find tint and the ink that reads on it, or clears both.
  func setTint(_ tint: NSColor?, ink: NSColor?) {
    self.tint = tint
    tintInk = tint == nil ? nil : ink
    layer?.backgroundColor = tint?.cgColor
    updateColor()
  }

  /// The parts of the text the filter matched, underlined in `underlineColor`.
  func setUnderlines(_ ranges: [NSRange], color: NSColor) {
    label.underlines = ranges
    underlineColor = color
    updateColor()
  }

  private var underlineColor = NSColor.clear

  /// The color the label draws in now.
  var currentTextColor: NSColor {
    if let tintInk { return tintInk }

    return backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : restingColor
  }

  /// The color the underline draws in now. Under the emphasized blue it takes the text's color, so
  /// it reads there too.
  var currentUnderlineColor: NSColor {
    if let tintInk { return tintInk }

    return backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : underlineColor
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
    label.textColor = currentTextColor
    label.underlineColor = currentUnderlineColor
    label.needsDisplay = true
  }
}

/// The cell's label, which draws the filter's underline itself.
///
/// AppKit's underline attribute picks its own thickness and offset from the font. The filter's mark
/// is a 2-point bar a little below the baseline, so the label measures where each matched range
/// falls and fills a rect under it.
@MainActor
final class DataCellLabel: NSTextField {
  var underlines: [NSRange] = [] {
    didSet { needsDisplay = true }
  }

  var underlineColor = NSColor.clear

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)

    guard !underlines.isEmpty, let cell, let font else { return }

    let text = stringValue as NSString
    let attributes: [NSAttributedString.Key: Any] = [.font: font]
    let textRect = cell.titleRect(forBounds: bounds)
    let full = text.size(withAttributes: attributes).width
    let padding: CGFloat = 2

    let start: CGFloat =
      switch alignment {
      case .right: textRect.maxX - padding - min(full, textRect.width - 2 * padding)
      default: textRect.minX + padding
      }

    // The line sits centered in the title rect. The descender is negative.
    let middle = (textRect.height - font.ascender + font.descender) / 2
    let baseline =
      isFlipped
      ? textRect.minY + middle + font.ascender : textRect.maxY - middle - font.ascender
    let y = baseline + (isFlipped ? 1 : -1) * DataCell.underlineOffset
    let limit = textRect.maxX - padding

    underlineColor.setFill()

    for range in underlines where NSMaxRange(range) <= text.length {
      let before = text.substring(to: range.location).size(withAttributes: attributes).width
      let width = text.substring(with: range).size(withAttributes: attributes).width
      let minX = start + before
      let maxX = min(limit, minX + width)

      guard maxX > minX else { continue }

      NSRect(
        x: minX, y: isFlipped ? y : y - DataCell.underlineThickness, width: maxX - minX,
        height: DataCell.underlineThickness
      ).fill()
    }
  }
}
