import AppKit
import Theme

/// The command palette's search field and the list of results under it.
///
/// This view is the field. The results live in a separate panel that the window places beside it,
/// over the pane area. A floating palette and a docked one share both. The field sits in the window
/// either way, and the panel opens away from it, so showing results never resizes a pane.
///
/// The view holds no commands. The window gives it entries and learns what the user chose. While
/// active, the keyboard belongs to the field. The arrow keys, Return, and Escape reach the list
/// through the field's delegate, and a click on a row never takes the keyboard from the field. An
/// inactive docked palette takes no keyboard at all. A click on it asks the window to activate it.
@MainActor
final class CommandPaletteView: NSView, NSTextFieldDelegate, NSTableViewDataSource,
  NSTableViewDelegate
{
  static let width: CGFloat = 560
  static let rowHeight: CGFloat = 28
  static let maximumVisibleRows = 8

  /// The padding between the results panel's border and its rows.
  static let resultsPadding: CGFloat = 6

  /// The sizes of the field's box. The text centers in it at its own height, so a taller box adds
  /// room above and below the text and never moves the text to the top.
  struct Style: Equatable {
    var height: CGFloat
    var fontSize: CGFloat
    var cornerRadius: CGFloat
    var textInset: CGFloat

    /// A floating palette is a card over the panes, so it has room for a larger field.
    static let floating = Style(height: 40, fontSize: 15, cornerRadius: 10, textInset: 14)

    /// A palette docked at the bottom sits in a strip that costs the panes its height.
    static let docked = Style(height: 24, fontSize: 13, cornerRadius: 6, textInset: 10)

    /// A palette docked at the top sits in the title bar row, beside the traffic lights.
    static let titleBar = Style(height: 22, fontSize: 13, cornerRadius: 6, textInset: 10)
  }

  /// How the window presents the palette. A floating palette is hidden until it is active. A docked
  /// one is always on show.
  enum Presentation {
    case floating
    case docked
  }

  let field = PaletteField()

  /// The results, in a view of their own so a docked palette can open them over the panes.
  let results = PaletteResultsPanel()

  private let table = PaletteTableView()
  private var palette: ThemePalette = .latte
  private var resultsHeight: NSLayoutConstraint?
  private var textLeading: NSLayoutConstraint?
  private var textTrailing: NSLayoutConstraint?

  private(set) var style: Style = .floating

  private(set) var presentation: Presentation = .floating
  private(set) var isActive = false

  /// The key equivalent of the menu item that activates the palette, spelled for a person. A docked
  /// palette names it in its placeholder while it is inactive.
  private(set) var hotkeyHint: String?

  /// The entries on show, best first.
  private(set) var entries: [PaletteEntry] = []

  /// The entry Return would run. It is an ID, so a list that re-sorts keeps the same entry
  /// highlighted.
  private(set) var selection: PaletteEntryID?

  /// Runs when the search text changes, with the new text.
  var onQueryChange: ((String) -> Void)?

  /// Runs when the user chooses an enabled entry, with Return or a click.
  var onChoose: ((PaletteEntry) -> Void)?

  /// Runs when the user asks to hide the palette with Escape.
  var onDismiss: (() -> Void)?

  /// Runs when the user clicks an inactive docked palette.
  var onActivate: (() -> Void)?

  var query: String { field.stringValue }

  override var isFlipped: Bool { true }

  override var wantsUpdateLayer: Bool { true }

  override var mouseDownCanMoveWindow: Bool { false }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)

    wantsLayer = true
    layer?.borderWidth = 1

    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.delegate = self
    field.translatesAutoresizingMaskIntoConstraints = false
    field.setAccessibilityIdentifier("command-palette-field")
    field.onInactiveClick = { [weak self] in self?.onActivate?() }
    addSubview(field)

    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry"))
    column.resizingMask = .autoresizingMask
    table.addTableColumn(column)
    table.style = .plain
    table.headerView = nil
    table.rowHeight = Self.rowHeight
    table.intercellSpacing = .zero
    table.selectionHighlightStyle = .none
    table.backgroundColor = .clear
    table.refusesFirstResponder = true
    table.dataSource = self
    table.delegate = self
    table.target = self
    table.action = #selector(rowClicked(_:))
    table.setAccessibilityIdentifier("command-palette-list")

    results.install(table)
    results.translatesAutoresizingMaskIntoConstraints = false

    // The panel's height is a preference. The window bounds it to the content area.
    let height = results.heightAnchor.constraint(equalToConstant: 0)
    height.priority = .defaultHigh
    height.isActive = true
    resultsHeight = height

    // The field keeps its own height, so its text is centered in the box at any box height.
    let leading = field.leadingAnchor.constraint(equalTo: leadingAnchor)
    let trailing = field.trailingAnchor.constraint(equalTo: trailingAnchor)
    textLeading = leading
    textTrailing = trailing

    NSLayoutConstraint.activate([
      field.centerYAnchor.constraint(equalTo: centerYAnchor),
      leading,
      trailing,
    ])

    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityIdentifier("command-palette")
    apply(style: .floating)
    updatePresentation()
  }

  /// Sizes the field's font, corners, and text inset. The window sets the box's height to match.
  func apply(style: Style) {
    self.style = style
    field.font = .systemFont(ofSize: style.fontSize)
    layer?.cornerRadius = style.cornerRadius
    textLeading?.constant = style.textInset
    textTrailing?.constant = -style.textInset
  }

  // MARK: Presentation

  /// Chooses floating or docked. The caller keeps the palette inactive across the change.
  func present(as presentation: Presentation) {
    self.presentation = presentation
    updatePresentation()
  }

  /// Activates the palette, or deactivates it. An active palette takes the keyboard and shows its
  /// results. An inactive floating palette is hidden, and an inactive docked one shows its
  /// placeholder.
  func setActive(_ active: Bool) {
    isActive = active
    updatePresentation()
  }

  func setHotkeyHint(_ hint: String?) {
    guard hint != hotkeyHint else { return }

    hotkeyHint = hint
    updatePresentation()
  }

  private func updatePresentation() {
    isHidden = presentation == .floating && !isActive
    field.acceptsKeyboard = presentation == .floating || isActive
    results.isHidden = !isActive || entries.isEmpty

    field.placeholderString = Self.placeholder(
      presentation: presentation, isActive: isActive, hint: hotkeyHint)
  }

  /// What the field says when it is empty. An inactive docked palette is the only place the user
  /// is told how to reach it, so it names the key.
  static func placeholder(presentation: Presentation, isActive: Bool, hint: String?) -> String {
    guard presentation == .docked, !isActive else { return "Search tabs and commands" }

    guard let hint else { return "Search tabs and commands" }

    return "Search tabs and commands (\(hint))"
  }

  /// Whether a point, in window coordinates, is on the field or on the results.
  func contains(windowPoint point: NSPoint) -> Bool {
    if bounds.contains(convert(point, from: nil)) { return true }

    return !results.isHidden && results.bounds.contains(results.convert(point, from: nil))
  }

  override func mouseDown(with event: NSEvent) {
    if isActive {
      super.mouseDown(with: event)
    } else {
      onActivate?()
    }
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override func updateLayer() {
    layer?.backgroundColor = palette[.mantle].cgColor
    layer?.borderColor = palette[.surface1].cgColor
  }

  func apply(_ palette: ThemePalette) {
    self.palette = palette
    field.textColor = palette[.text].nsColor
    needsDisplay = true
    results.apply(palette)
    table.reloadData()
  }

  // MARK: Entries

  /// Shows a fresh list. The selection stays on its entry when the entry is still there and can
  /// run. Otherwise it moves to the first entry that can run.
  ///
  /// With no query, the first choice is the most recent tab other than the current one, so Return
  /// goes back to where the user was. With no other tab it is the first other entry that can run.
  func setEntries(_ entries: [PaletteEntry]) {
    self.entries = entries

    // The same entry stays highlighted, wherever it sorted to.
    if selection.map({ id in !entries.contains { $0.id == id && $0.isEnabled } }) ?? true {
      selection = Self.firstChoice(in: entries, emptyQuery: PaletteRanking.isEmpty(query))
    }

    let rows = min(entries.count, Self.maximumVisibleRows)
    resultsHeight?.constant = CGFloat(rows) * Self.rowHeight + 2 * Self.resultsPadding
    results.isHidden = !isActive || entries.isEmpty

    table.reloadData()
    scrollToSelection()
  }

  private static func firstChoice(in entries: [PaletteEntry], emptyQuery: Bool) -> PaletteEntryID? {
    let enabled = entries.filter(\.isEnabled)

    guard emptyQuery else { return enabled.first?.id }

    let others = enabled.filter { !$0.isCurrent }

    return (others.first { $0.kind == .tab } ?? others.first ?? enabled.first)?.id
  }

  /// Clears the text and the selection for the next time the palette shows.
  func reset() {
    field.stringValue = ""
    selection = nil
    entries = []
    results.isHidden = true
    table.reloadData()
  }

  var selectedEntry: PaletteEntry? {
    entries.first { $0.id == selection }
  }

  private func moveSelection(by step: Int) {
    let enabled = entries.filter(\.isEnabled)

    guard !enabled.isEmpty else { return }

    let current = enabled.firstIndex { $0.id == selection } ?? (step > 0 ? -1 : enabled.count)
    let next = min(max(current + step, 0), enabled.count - 1)

    selection = enabled[next].id
    table.reloadData()
    scrollToSelection()
  }

  private func scrollToSelection() {
    if let row = entries.firstIndex(where: { $0.id == selection }) {
      table.scrollRowToVisible(row)
    }
  }

  private func chooseSelection() {
    guard let entry = selectedEntry, entry.isEnabled else { return }

    onChoose?(entry)
  }

  @objc private func rowClicked(_ sender: Any?) {
    let row = table.clickedRow

    guard entries.indices.contains(row), entries[row].isEnabled else { return }

    selection = entries[row].id
    chooseSelection()
  }

  // MARK: Field delegate

  func controlTextDidChange(_ notification: Notification) {
    // New text picks the first choice again. Only a re-list from the tabs keeps the highlight.
    selection = nil
    onQueryChange?(field.stringValue)
  }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    switch selector {
    case #selector(NSResponder.moveDown(_:)):
      moveSelection(by: 1)

    case #selector(NSResponder.moveUp(_:)):
      moveSelection(by: -1)

    case #selector(NSResponder.insertNewline(_:)):
      chooseSelection()

    case #selector(NSResponder.cancelOperation(_:)):
      onDismiss?()

    default:
      return false
    }

    return true
  }

  // MARK: Table

  func numberOfRows(in tableView: NSTableView) -> Int {
    entries.count
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
    -> NSView?
  {
    let view = PaletteRowView()
    view.configure(entries[row], selected: entries[row].id == selection, palette: palette)
    return view
  }
}

/// The search field. An inactive docked palette must not take the keyboard, not even from a click.
/// The click asks the window to activate the palette instead.
@MainActor
final class PaletteField: NSTextField {
  var acceptsKeyboard = true
  var onInactiveClick: (() -> Void)?

  override var acceptsFirstResponder: Bool { acceptsKeyboard && super.acceptsFirstResponder }

  override func mouseDown(with event: NSEvent) {
    if acceptsKeyboard {
      super.mouseDown(with: event)
    } else {
      onInactiveClick?()
    }
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The results list. It is a card of its own, placed beside the field and over the panes.
@MainActor
final class PaletteResultsPanel: NSView {
  private let scroll = NSScrollView()
  private var palette: ThemePalette = .latte

  override var isFlipped: Bool { true }

  override var wantsUpdateLayer: Bool { true }

  override var mouseDownCanMoveWindow: Bool { false }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)

    wantsLayer = true
    layer?.cornerRadius = 10
    layer?.borderWidth = 1
    layer?.masksToBounds = true

    scroll.hasVerticalScroller = true
    scroll.automaticallyAdjustsContentInsets = false
    scroll.contentInsets = NSEdgeInsetsZero
    scroll.drawsBackground = false
    scroll.borderType = .noBorder
    scroll.translatesAutoresizingMaskIntoConstraints = false
    addSubview(scroll)

    let padding = CommandPaletteView.resultsPadding

    NSLayoutConstraint.activate([
      scroll.topAnchor.constraint(equalTo: topAnchor, constant: padding),
      scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding),
      scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
      scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
    ])

    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityIdentifier("command-palette-results")
    isHidden = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  func install(_ table: NSTableView) {
    scroll.documentView = table
  }

  func apply(_ palette: ThemePalette) {
    self.palette = palette
    needsDisplay = true
  }

  override func updateLayer() {
    layer?.backgroundColor = palette[.mantle].cgColor
    layer?.borderColor = palette[.surface1].cgColor
  }
}

/// A table that never takes the keyboard, so the field keeps it while the user clicks a row.
private final class PaletteTableView: NSTableView {
  override var acceptsFirstResponder: Bool { false }
}

/// One result row: an icon, the title, and on the right the applet's name or the kind.
private final class PaletteRowView: NSView {
  static let iconSize: CGFloat = 14

  private let icon = NSImageView()
  private let title = NSTextField(labelWithString: "")
  private let kind = NSTextField(labelWithString: "")

  override var isFlipped: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)

    wantsLayer = true
    layer?.cornerRadius = 6

    // The icon keeps its place when a row has none, so every title starts at the same edge.
    icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
    icon.imageScaling = .scaleProportionallyDown
    icon.translatesAutoresizingMaskIntoConstraints = false
    addSubview(icon)

    title.font = .systemFont(ofSize: 13)
    title.lineBreakMode = .byTruncatingTail
    title.translatesAutoresizingMaskIntoConstraints = false
    title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    addSubview(title)

    kind.font = .systemFont(ofSize: 11)
    kind.translatesAutoresizingMaskIntoConstraints = false
    kind.setContentHuggingPriority(.required, for: .horizontal)
    addSubview(kind)

    NSLayoutConstraint.activate([
      icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      icon.centerYAnchor.constraint(equalTo: centerYAnchor),
      icon.widthAnchor.constraint(equalToConstant: Self.iconSize),
      icon.heightAnchor.constraint(equalToConstant: Self.iconSize),
      title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
      title.centerYAnchor.constraint(equalTo: centerYAnchor),
      kind.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      kind.centerYAnchor.constraint(equalTo: centerYAnchor),
      title.trailingAnchor.constraint(lessThanOrEqualTo: kind.leadingAnchor, constant: -12),
    ])

    setAccessibilityElement(true)
    setAccessibilityRole(.row)
    setAccessibilityIdentifier("command-palette-row")
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  func configure(_ entry: PaletteEntry, selected: Bool, palette: ThemePalette) {
    kind.stringValue = entry.label
    icon.image = entry.symbolName.flatMap {
      NSImage(systemSymbolName: $0, accessibilityDescription: nil)
    }

    let onAccent = palette.flavor == .latte ? palette[.base] : palette[.crust]

    let titleColor: NSColor
    let detailColor: NSColor

    if selected {
      layer?.backgroundColor = palette[.blue].cgColor
      titleColor = onAccent.nsColor
      detailColor = onAccent.nsColor
      kind.textColor = onAccent.nsColor
      icon.contentTintColor = onAccent.nsColor
    } else {
      layer?.backgroundColor = NSColor.clear.cgColor
      titleColor = entry.isEnabled ? palette[.text].nsColor : palette[.overlay0].nsColor
      detailColor = palette[.overlay1].nsColor
      kind.textColor = palette[.overlay1].nsColor
      icon.contentTintColor = palette[.overlay1].nsColor
    }

    let truncating = NSMutableParagraphStyle()
    truncating.lineBreakMode = .byTruncatingTail

    let text = NSMutableAttributedString(
      string: entry.title,
      attributes: [
        .foregroundColor: titleColor, .font: NSFont.systemFont(ofSize: 13),
        .paragraphStyle: truncating,
      ])

    if let detail = entry.detail, !detail.isEmpty {
      text.append(
        NSAttributedString(
          string: "  " + detail,
          attributes: [
            .foregroundColor: detailColor, .font: NSFont.systemFont(ofSize: 11),
            .paragraphStyle: truncating,
          ]))
    }

    title.attributedStringValue = text

    setAccessibilityLabel(entry.title)
    setAccessibilityValue("\(entry.label), \(entry.isEnabled ? "enabled" : "disabled")")
    setAccessibilityHelp(entry.detail)
    setAccessibilitySelected(selected)
  }
}
