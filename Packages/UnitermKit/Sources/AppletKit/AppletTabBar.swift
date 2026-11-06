import AppKit
import Theme

/// One tab in the bar: a title, and a control that closes it.
@MainActor
final class AppletTabItem: NSView {
  private let label = NSTextField(labelWithString: "")
  private let closeButton = NSButton()
  private var palette: ThemePalette = .latte

  var index = 0 {
    didSet { refreshAccessibility() }
  }

  var title = "" {
    didSet {
      label.stringValue = title
      refreshAccessibility()
    }
  }

  var isSelected = false {
    didSet { refresh() }
  }

  var onSelect: (() -> Void)?
  var onClose: (() -> Void)?

  override var mouseDownCanMoveWindow: Bool { false }

  override init(frame: NSRect) {
    super.init(frame: frame)

    wantsLayer = true
    layer?.cornerRadius = 5

    label.lineBreakMode = .byTruncatingTail
    label.font = .systemFont(ofSize: 12)
    label.setAccessibilityElement(false)
    addSubview(label)

    closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")
    closeButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
    closeButton.imagePosition = .imageOnly
    closeButton.isBordered = false
    closeButton.target = self
    closeButton.action = #selector(closeClicked(_:))
    addSubview(closeButton)

    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    refresh()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override func layout() {
    super.layout()

    let side: CGFloat = 16
    closeButton.frame = NSRect(
      x: bounds.maxX - side - 6, y: (bounds.height - side) / 2, width: side, height: side)

    let height = label.intrinsicContentSize.height
    label.frame = NSRect(
      x: 10, y: (bounds.height - height) / 2, width: max(0, closeButton.frame.minX - 14),
      height: height)
  }

  override func mouseDown(with event: NSEvent) {
    onSelect?()
  }

  override func accessibilityPerformPress() -> Bool {
    onSelect?()
    return true
  }

  @objc private func closeClicked(_ sender: Any?) {
    onClose?()
  }

  func apply(_ palette: ThemePalette) {
    self.palette = palette
    refresh()
  }

  private func refresh() {
    layer?.backgroundColor = isSelected ? palette[.base].cgColor : NSColor.clear.cgColor
    label.textColor = (isSelected ? palette[.text] : palette[.subtext0]).nsColor
    closeButton.contentTintColor = palette[.overlay1].nsColor
    refreshAccessibility()
  }

  private func refreshAccessibility() {
    setAccessibilityIdentifier("tab-\(index)")
    setAccessibilityLabel(title)
    setAccessibilityValue(isSelected ? "selected" : "unselected")
    closeButton.setAccessibilityIdentifier("tab-close-\(index)")
    closeButton.setAccessibilityLabel("Close \(title)")
  }
}

/// The strip of tabs above an applet's content. The applet hides it while it has one tab.
@MainActor
public final class AppletTabBar: NSView {
  public static let height: CGFloat = 28

  private static let gap: CGFloat = 2
  private static let inset: CGFloat = 4
  private static let narrowest: CGFloat = 80
  private static let widest: CGFloat = 200

  private var items: [AppletTabItem] = []
  private let newButton = NSButton()
  private var palette: ThemePalette = .latte

  public var onSelect: ((Int) -> Void)?
  public var onClose: ((Int) -> Void)?
  public var onNew: (() -> Void)?

  override public var isFlipped: Bool { true }

  override public var mouseDownCanMoveWindow: Bool { false }

  override public init(frame: NSRect) {
    super.init(frame: frame)

    wantsLayer = true

    newButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New tab")
    newButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
    newButton.imagePosition = .imageOnly
    newButton.isBordered = false
    newButton.target = self
    newButton.action = #selector(newClicked(_:))
    newButton.setAccessibilityIdentifier("new-tab")
    newButton.setAccessibilityLabel("New tab")
    addSubview(newButton)

    refreshColors()
  }

  @available(*, unavailable)
  public required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  /// Shows one item for each title and marks the selected one. The new-tab control shows only when
  /// the applet can open a tab.
  public func update(titles: [String], selected: Int, canOpenTab: Bool) {
    while items.count > titles.count {
      items.removeLast().removeFromSuperview()
    }

    while items.count < titles.count {
      let item = AppletTabItem(frame: .zero)
      item.apply(palette)
      addSubview(item)
      items.append(item)
    }

    for (index, item) in items.enumerated() {
      item.index = index
      item.title = titles[index]
      item.isSelected = index == selected
      item.onSelect = { [weak self] in self?.onSelect?(index) }
      item.onClose = { [weak self] in self?.onClose?(index) }
    }

    newButton.isHidden = !canOpenTab
    needsLayout = true
  }

  override public func layout() {
    super.layout()

    let side: CGFloat = 22
    let trailing = newButton.isHidden ? 0 : side + Self.inset
    let available = bounds.width - 2 * Self.inset - trailing
    let count = CGFloat(max(items.count, 1))
    let width = min(
      Self.widest, max(Self.narrowest, (available - Self.gap * (count - 1)) / count))

    var x = Self.inset
    let itemHeight = bounds.height - 6

    for item in items {
      item.frame = NSRect(x: x, y: 3, width: width, height: itemHeight)
      x += width + Self.gap
    }

    newButton.frame = NSRect(
      x: min(x, bounds.width - side - Self.inset), y: (bounds.height - side) / 2, width: side,
      height: side)
  }

  @objc private func newClicked(_ sender: Any?) {
    onNew?()
  }

  public func apply(_ palette: ThemePalette) {
    self.palette = palette

    for item in items { item.apply(palette) }

    refreshColors()
  }

  private func refreshColors() {
    layer?.backgroundColor = palette[.mantle].cgColor
    newButton.contentTintColor = palette[.overlay1].nsColor
  }
}
