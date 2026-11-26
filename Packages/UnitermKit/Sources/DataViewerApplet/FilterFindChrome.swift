import AppKit
import Theme

// MARK: Colors

/// The colors that tell the filter and the find apart, derived from the theme palette.
///
/// The filter is mauve and the find is amber, from the palette's yellow. A caption in an accent
/// color is drawn darker or lighter, toward the palette's text, until it reaches 4.5:1 against what
/// it sits on, so each flavor gets its own readable shade. Text on a match tint is the palette's
/// text or base, whichever reads better on that tint.
struct FilterFindColors {
  let filterAccent: NSColor
  let filterUnderline: NSColor
  let findStrip: NSColor
  let findBorder: NSColor
  let findAccent: NSColor
  let strongMatch: NSColor
  let paleMatch: NSColor
  let inkOnStrongMatch: NSColor
  let inkOnPaleMatch: NSColor

  static let textContrast = 4.5

  init(_ palette: ThemePalette) {
    let base = palette[.base].nsColor
    let text = palette[.text].nsColor
    let yellow = palette[.yellow].nsColor
    let mauve = palette[.mauve].nsColor

    filterAccent = Contrast.readable(mauve, on: base, toward: text)
    filterUnderline = mauve
    findStrip = Contrast.blend(yellow, alpha: 0.14, over: base)
    findBorder = Contrast.blend(yellow, alpha: 0.8, over: base)
    findAccent = Contrast.readable(yellow, on: findStrip, toward: text)
    let ink = { (tint: NSColor) -> NSColor in
      Contrast.ratio(text, tint) >= Contrast.ratio(base, tint) ? text : base
    }

    // The strong tint is as amber as it can be while its text still reads.
    var strong = Contrast.blend(yellow, alpha: 0.75, over: base)

    for alpha in stride(from: 0.75, through: 0.3, by: -0.05) {
      strong = Contrast.blend(yellow, alpha: alpha, over: base)

      if Contrast.ratio(ink(strong), strong) >= Self.textContrast { break }
    }

    strongMatch = strong
    paleMatch = Contrast.blend(yellow, alpha: 0.25, over: base)
    inkOnStrongMatch = ink(strongMatch)
    inkOnPaleMatch = ink(paleMatch)
  }
}

/// WCAG contrast for opaque sRGB colors.
enum Contrast {
  static func ratio(_ first: NSColor, _ second: NSColor) -> Double {
    let a = luminance(first)
    let b = luminance(second)

    return (max(a, b) + 0.05) / (min(a, b) + 0.05)
  }

  static func luminance(_ color: NSColor) -> Double {
    let rgb = color.usingColorSpace(.sRGB) ?? color

    func channel(_ value: CGFloat) -> Double {
      let value = Double(value)

      return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    return 0.2126 * channel(rgb.redComponent) + 0.7152 * channel(rgb.greenComponent)
      + 0.0722 * channel(rgb.blueComponent)
  }

  /// A translucent `color` laid over `background`, as one opaque color.
  static func blend(_ color: NSColor, alpha: CGFloat, over background: NSColor) -> NSColor {
    let back = background.usingColorSpace(.sRGB) ?? background

    return back.blended(withFraction: alpha, of: color.usingColorSpace(.sRGB) ?? color) ?? color
  }

  /// `color`, moved toward `ink` in steps until it reads at text contrast on `background`.
  static func readable(_ color: NSColor, on background: NSColor, toward ink: NSColor) -> NSColor {
    let start = color.usingColorSpace(.sRGB) ?? color

    for step in 0...10 {
      let candidate = start.blended(withFraction: CGFloat(step) / 10, of: ink) ?? ink

      if ratio(candidate, background) >= FilterFindColors.textContrast { return candidate }
    }

    return ink
  }
}

// MARK: Filter field

/// The filter's search field: a funnel where the magnifier would be, and the row count inside the
/// field on the right, beside the clear button.
@MainActor
final class FilterField: NSSearchField {
  let countLabel = NSTextField(labelWithString: "")

  override class var cellClass: AnyClass? {
    get { FilterFieldCell.self }
    set {}
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)

    if let cell = cell as? NSSearchFieldCell {
      cell.searchButtonCell?.image = NSImage(
        systemSymbolName: "line.3.horizontal.decrease", accessibilityDescription: "Filter")
    }

    countLabel.font = .monospacedDigitSystemFont(
      ofSize: NSFont.smallSystemFontSize, weight: .regular)
    countLabel.alignment = .right
    countLabel.setAccessibilityIdentifier("data-viewer-filter-count")
    addSubview(countLabel)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  /// The row count, such as "5 of 250 rows", or empty for none.
  var count: String {
    get { countLabel.stringValue }
    set {
      guard newValue != countLabel.stringValue else { return }

      countLabel.stringValue = newValue
      countLabel.isHidden = newValue.isEmpty
      needsLayout = true
    }
  }

  override func layout() {
    super.layout()

    guard let cell = cell as? FilterFieldCell else { return }

    let width = countLabel.isHidden ? 0 : ceil(countLabel.fittingSize.width)
    cell.reservedTrailing = width > 0 ? width + 6 : 0

    let cancel = cell.cancelButtonRect(forBounds: bounds)
    let height = countLabel.fittingSize.height

    countLabel.frame = NSRect(
      x: cancel.minX - width - 2, y: (bounds.height - height) / 2, width: width, height: height)
  }
}

/// Keeps the typed text clear of the row count.
final class FilterFieldCell: NSSearchFieldCell {
  var reservedTrailing: CGFloat = 0

  override func searchTextRect(forBounds rect: NSRect) -> NSRect {
    var text = super.searchTextRect(forBounds: rect)
    text.size.width = max(0, text.width - reservedTrailing)

    return text
  }
}

// MARK: Captions

/// A small bold caption, such as "FILTER", in an accent color. It reads as a label for the control
/// beside it.
@MainActor
func makeCaption(_ text: String, label: String, identifier: String) -> NSTextField {
  let caption = NSTextField(labelWithString: text)
  caption.font = .systemFont(ofSize: NSFont.smallSystemFontSize - 1, weight: .bold)
  caption.setContentHuggingPriority(.required, for: .horizontal)
  caption.setContentCompressionResistancePriority(.required, for: .horizontal)
  caption.setAccessibilityLabel(label)
  caption.setAccessibilityIdentifier(identifier)

  return caption
}

// MARK: Find strip

/// The find bar: its own tinted strip with an amber border, a caption, the query, the match count,
/// previous and next buttons, and Done.
@MainActor
final class FindStrip: NSView {
  let caption = makeCaption("FIND", label: "Find", identifier: "data-viewer-find-caption")
  let previousButton = NSButton()
  let nextButton = NSButton()
  let doneButton = NSButton(title: "Done", target: nil, action: nil)
  private let row = NSStackView()

  var onStep: ((Bool) -> Void)?
  var onDone: (() -> Void)?

  init(field: NSSearchField, count: NSTextField, suffix: String) {
    super.init(frame: .zero)

    wantsLayer = true
    layer?.cornerRadius = 6
    layer?.borderWidth = 1
    setAccessibilityIdentifier("data-viewer-find-bar\(suffix)")

    configure(previousButton, symbol: "chevron.up", label: "Previous match", id: "previous")
    configure(nextButton, symbol: "chevron.down", label: "Next match", id: "next")
    previousButton.action = #selector(previousPressed)
    nextButton.action = #selector(nextPressed)

    doneButton.bezelStyle = .rounded
    doneButton.controlSize = .small
    doneButton.target = self
    doneButton.action = #selector(donePressed)
    doneButton.setAccessibilityLabel("Close the find bar")
    doneButton.setAccessibilityIdentifier("data-viewer-find-done\(suffix)")

    for view in [caption, field, count, previousButton, nextButton, doneButton] as [NSView] {
      row.addArrangedSubview(view)
    }

    row.orientation = .horizontal
    row.spacing = 6
    row.alignment = .centerY
    row.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 6)
    row.translatesAutoresizingMaskIntoConstraints = false
    addSubview(row)

    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: leadingAnchor),
      row.trailingAnchor.constraint(equalTo: trailingAnchor),
      row.topAnchor.constraint(equalTo: topAnchor),
      row.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  private func configure(_ button: NSButton, symbol: String, label: String, id: String) {
    button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
    button.bezelStyle = .texturedRounded
    button.controlSize = .small
    button.target = self
    button.toolTip = label
    button.setAccessibilityLabel(label)
    button.setAccessibilityIdentifier("data-viewer-find-\(id)")
  }

  func apply(_ colors: FilterFindColors) {
    layer?.backgroundColor = colors.findStrip.cgColor
    layer?.borderColor = colors.findBorder.cgColor
    caption.textColor = colors.findAccent
  }

  func update(hasMatch: Bool) {
    previousButton.isEnabled = hasMatch
    nextButton.isEnabled = hasMatch
  }

  @objc private func previousPressed() { onStep?(false) }

  @objc private func nextPressed() { onStep?(true) }

  @objc private func donePressed() { onDone?() }
}
