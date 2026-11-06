import AppKit
import Theme

/// One row of the launcher: an icon, a name, a detail line, and the key that picks it.
@MainActor
final class LauncherRowView: NSView {
  /// The gap between a row's edge and its icon.
  static let inset: CGFloat = 10
  static let tileSize: CGFloat = 28
  static let gap: CGFloat = 12

  /// Where a row's text starts, measured from the row's left edge. The command field indents to it.
  static let textLeading = inset + tileSize + gap

  let kind: LauncherEntry.Kind

  var onSelect: (() -> Void)?
  var onOpen: (() -> Void)?

  private let tile = NSView()
  private let icon = NSImageView()
  private let nameLabel: NSTextField
  private let detailLabel: NSTextField
  private let keyLabel = NSTextField(labelWithString: "")
  private var palette: ThemePalette = .latte

  var keyText = "" {
    didSet { keyLabel.stringValue = keyText }
  }

  var isSelected = false {
    didSet { restyle() }
  }

  override var isFlipped: Bool { true }

  override var mouseDownCanMoveWindow: Bool { false }

  init(entry: LauncherEntry) {
    kind = entry.kind
    nameLabel = NSTextField(labelWithString: entry.name)
    detailLabel = NSTextField(labelWithString: entry.detail)

    super.init(frame: .zero)

    wantsLayer = true
    layer?.cornerRadius = 8

    tile.wantsLayer = true
    tile.layer?.cornerRadius = 6
    tile.translatesAutoresizingMaskIntoConstraints = false

    icon.image = NSImage(systemSymbolName: entry.symbol, accessibilityDescription: nil)
    icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
    icon.translatesAutoresizingMaskIntoConstraints = false
    tile.addSubview(icon)

    nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
    detailLabel.font = .systemFont(ofSize: 11)
    keyLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)

    for label in [nameLabel, detailLabel] {
      label.lineBreakMode = .byTruncatingTail
      label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    let text = NSStackView(views: [nameLabel, detailLabel])
    text.orientation = .vertical
    text.alignment = .leading
    text.spacing = 1

    let row = NSStackView(views: [tile, text, keyLabel])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = Self.gap
    row.translatesAutoresizingMaskIntoConstraints = false
    text.setHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
    keyLabel.setContentHuggingPriority(.required, for: .horizontal)
    keyLabel.alignment = .right
    addSubview(row)

    NSLayoutConstraint.activate([
      tile.widthAnchor.constraint(equalToConstant: Self.tileSize),
      tile.heightAnchor.constraint(equalToConstant: Self.tileSize),
      icon.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
      icon.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
      row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
      row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
      row.topAnchor.constraint(equalTo: topAnchor, constant: 8),
      row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
    ])

    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    setAccessibilityLabel(entry.name)
    setAccessibilityIdentifier(entry.kind.accessibilityIdentifier)
    restyle()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  func apply(_ palette: ThemePalette) {
    self.palette = palette
    restyle()
  }

  override func mouseDown(with event: NSEvent) {
    if event.clickCount >= 2 {
      onOpen?()
    } else {
      onSelect?()
    }
  }

  private func restyle() {
    let text: NSColor
    let tileColor: NSColor
    let iconColor: NSColor

    if isSelected {
      text = palette.onAccent.nsColor
      tileColor = text.withAlphaComponent(0.22)
      iconColor = text
      layer?.backgroundColor = palette[.blue].cgColor
    } else {
      text = palette[.text].nsColor
      tileColor = palette[.mantle].nsColor
      iconColor = palette[.subtext0].nsColor
      layer?.backgroundColor = NSColor.clear.cgColor
    }

    tile.layer?.backgroundColor = tileColor.cgColor
    icon.contentTintColor = iconColor
    nameLabel.textColor = text
    detailLabel.textColor = text.withAlphaComponent(0.75)
    keyLabel.textColor = text.withAlphaComponent(0.7)
    setAccessibilityValue(isSelected ? "selected" : "")
  }
}

/// A rounded box that holds a text field, with a border in a palette color.
@MainActor
final class LauncherFieldBox: NSView {
  var fill: ThemeToken = .mantle
  var border: ThemeToken = .surface0

  override var isFlipped: Bool { true }

  init() {
    super.init(frame: .zero)

    wantsLayer = true
    layer?.cornerRadius = 8
    layer?.borderWidth = 1
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  func apply(_ palette: ThemePalette) {
    layer?.backgroundColor = palette[fill].cgColor
    layer?.borderColor = palette[border].cgColor
  }
}

/// What a new pane shows until the user picks an applet.
///
/// The view owns the model and turns keys and clicks into model changes. It never opens an applet
/// itself. `onChoose` does, and may throw to refuse. `onExit` asks to close the empty pane.
///
/// The keyboard always belongs to a text field. The filter has it by default, and the command
/// field has it while the program entry is selected. The arrow keys, Return, and Escape reach the
/// model through the fields' delegate.
///
/// Command-1 to Command-9 reach it through `performKeyEquivalent`, which the window asks before
/// the main menu, so the Window menu's tab items never see them. The view takes them only while
/// the keyboard is inside it.
@MainActor
final class LauncherView: NSView, NSTextFieldDelegate {
  private(set) var model = LauncherModel()

  var onChoose: ((AppletChoice) throws -> Void)?
  var onExit: (() -> Void)?

  let filterField = NSTextField()
  let commandField = NSTextField()

  let titleLabel = NSTextField(labelWithString: "New pane")
  let subtitleLabel = NSTextField(
    labelWithString: "Choose what runs here. Return opens a terminal.")
  private let magnifier = NSImageView()
  let filterBox = LauncherFieldBox()
  let commandBox = LauncherFieldBox()
  let stage = NSView()
  private let commandCaption = NSTextField(labelWithString: "Command")
  private let errorLabel = NSTextField(wrappingLabelWithString: "")
  private let emptyLabel = NSTextField(labelWithString: "No applet matches.")
  private let commandWrapper = NSView()
  private let hintBar = NSView()
  private let hintRule = NSView()
  private let hintLabel = NSTextField(wrappingLabelWithString: LauncherView.hint)
  private(set) var rows: [LauncherRowView] = []
  private var palette: ThemePalette = .latte

  static let hint =
    "Type to filter \u{00B7} \u{2191}\u{2193} Choose \u{00B7} \u{21A9} Open \u{00B7} "
    + "\u{2318}1\u{2013}\u{2318}9 Pick \u{00B7} esc Back, then close"

  override var isFlipped: Bool { true }

  override var mouseDownCanMoveWindow: Bool { false }

  init() {
    super.init(frame: .zero)

    wantsLayer = true
    build()
    apply(.latte)
    render()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  // MARK: Building

  private func build() {
    titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
    subtitleLabel.font = .systemFont(ofSize: 12)

    let header = NSStackView(views: [titleLabel, subtitleLabel])
    header.orientation = .vertical
    header.alignment = .leading
    header.spacing = 2
    pinWidths(of: [titleLabel, subtitleLabel], to: header)

    for label in [titleLabel, subtitleLabel] {
      label.alignment = .left
      label.lineBreakMode = .byTruncatingTail
      label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    magnifier.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
    magnifier.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)

    configure(filterField, font: .systemFont(ofSize: 13), placeholder: "Type to filter")
    filterField.setAccessibilityIdentifier("launcher-filter")
    filterField.setAccessibilityLabel("Filter applets")
    place(filterField, with: magnifier, in: filterBox)

    configure(
      commandField, font: .monospacedSystemFont(ofSize: 12, weight: .regular),
      placeholder: "htop or tail -f log")
    commandField.setAccessibilityIdentifier("launcher-command")
    commandField.setAccessibilityLabel("Command")
    commandCaption.font = .systemFont(ofSize: 12)
    commandBox.border = .blue
    place(commandField, with: commandCaption, in: commandBox)

    errorLabel.font = .systemFont(ofSize: 11)
    errorLabel.setAccessibilityIdentifier("launcher-error")

    let command = NSStackView(views: [commandBox, errorLabel])
    command.orientation = .vertical
    command.alignment = .leading
    command.spacing = 4
    command.translatesAutoresizingMaskIntoConstraints = false
    commandWrapper.addSubview(command)

    pinWidths(of: [commandBox, errorLabel], to: command)

    NSLayoutConstraint.activate([
      command.leadingAnchor.constraint(
        equalTo: commandWrapper.leadingAnchor, constant: LauncherRowView.textLeading),
      command.trailingAnchor.constraint(equalTo: commandWrapper.trailingAnchor),
      command.topAnchor.constraint(equalTo: commandWrapper.topAnchor, constant: 4),
      command.bottomAnchor.constraint(equalTo: commandWrapper.bottomAnchor, constant: -4),
    ])

    emptyLabel.font = .systemFont(ofSize: 12)
    emptyLabel.setAccessibilityIdentifier("launcher-empty")

    let list = NSStackView()
    list.orientation = .vertical
    list.alignment = .leading
    list.spacing = 2

    for entry in LauncherEntry.all {
      let row = LauncherRowView(entry: entry)
      row.onSelect = { [weak self] in self?.choose(entry.kind) }
      row.onOpen = { [weak self] in
        self?.choose(entry.kind)
        self?.open()
      }

      rows.append(row)
      list.addArrangedSubview(row)

      if entry.kind == .program {
        list.addArrangedSubview(commandWrapper)
      }
    }

    list.addArrangedSubview(emptyLabel)
    pinWidths(of: list.arrangedSubviews, to: list)

    let card = NSStackView(views: [header, filterBox, list])
    card.orientation = .vertical
    card.alignment = .leading
    pinWidths(of: card.arrangedSubviews, to: card)
    card.spacing = 12
    card.translatesAutoresizingMaskIntoConstraints = false

    stage.translatesAutoresizingMaskIntoConstraints = false
    stage.wantsLayer = true
    stage.layer?.masksToBounds = true
    stage.addSubview(card)

    hintLabel.font = .systemFont(ofSize: 11)
    hintLabel.alignment = .center
    hintLabel.translatesAutoresizingMaskIntoConstraints = false
    hintLabel.setAccessibilityIdentifier("launcher-hint")
    hintRule.wantsLayer = true
    hintRule.translatesAutoresizingMaskIntoConstraints = false
    hintBar.translatesAutoresizingMaskIntoConstraints = false
    hintBar.addSubview(hintRule)
    hintBar.addSubview(hintLabel)

    addSubview(stage)
    addSubview(hintBar)

    let preferredWidth = card.widthAnchor.constraint(equalToConstant: 380)
    preferredWidth.priority = .defaultHigh

    // A pane narrower than the card squeezes it. The margins give way before the window's
    // required constraints do, so a pane at its minimum size does not log a conflict.
    let margins = [
      card.leadingAnchor.constraint(greaterThanOrEqualTo: stage.leadingAnchor, constant: 16),
      card.trailingAnchor.constraint(lessThanOrEqualTo: stage.trailingAnchor, constant: -16),
      card.topAnchor.constraint(greaterThanOrEqualTo: stage.topAnchor, constant: 8),
      card.bottomAnchor.constraint(lessThanOrEqualTo: stage.bottomAnchor, constant: -8),
    ]

    for margin in margins {
      margin.priority = NSLayoutConstraint.Priority(760)
    }

    NSLayoutConstraint.activate(margins)

    // Centered while the card fits. When it is taller than the pane, the top margin wins, so the
    // title stays in view and the stage clips the rest.
    let centered = card.centerYAnchor.constraint(equalTo: stage.centerYAnchor)
    centered.priority = NSLayoutConstraint.Priority(740)
    centered.isActive = true

    NSLayoutConstraint.activate([
      stage.leadingAnchor.constraint(equalTo: leadingAnchor),
      stage.trailingAnchor.constraint(equalTo: trailingAnchor),
      stage.topAnchor.constraint(equalTo: topAnchor),
      stage.bottomAnchor.constraint(equalTo: hintBar.topAnchor),
      hintBar.leadingAnchor.constraint(equalTo: leadingAnchor),
      hintBar.trailingAnchor.constraint(equalTo: trailingAnchor),
      hintBar.bottomAnchor.constraint(equalTo: bottomAnchor),
      card.centerXAnchor.constraint(equalTo: stage.centerXAnchor),
      preferredWidth,
      hintRule.leadingAnchor.constraint(equalTo: hintBar.leadingAnchor),
      hintRule.trailingAnchor.constraint(equalTo: hintBar.trailingAnchor),
      hintRule.topAnchor.constraint(equalTo: hintBar.topAnchor),
      hintRule.heightAnchor.constraint(equalToConstant: 1),
      hintLabel.leadingAnchor.constraint(equalTo: hintBar.leadingAnchor, constant: 12),
      hintLabel.trailingAnchor.constraint(equalTo: hintBar.trailingAnchor, constant: -12),
      hintLabel.topAnchor.constraint(equalTo: hintBar.topAnchor, constant: 10),
      hintLabel.bottomAnchor.constraint(equalTo: hintBar.bottomAnchor, constant: -10),
    ])

    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityIdentifier("launcher")
  }

  /// Stretches each view to the stack's width. A vertical stack's own alignment would only match
  /// the widths of its views to each other.
  private func pinWidths(of views: [NSView], to stack: NSStackView) {
    for view in views {
      view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
  }

  private func configure(_ field: NSTextField, font: NSFont, placeholder: String) {
    field.font = font
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.usesSingleLineMode = true
    field.cell?.isScrollable = true
    field.placeholderString = placeholder
    field.delegate = self
    field.translatesAutoresizingMaskIntoConstraints = false
  }

  private func place(_ field: NSTextField, with lead: NSView, in box: LauncherFieldBox) {
    lead.translatesAutoresizingMaskIntoConstraints = false
    box.translatesAutoresizingMaskIntoConstraints = false
    box.addSubview(lead)
    box.addSubview(field)

    lead.setContentHuggingPriority(.required, for: .horizontal)
    lead.setContentCompressionResistancePriority(.required, for: .horizontal)

    NSLayoutConstraint.activate([
      box.heightAnchor.constraint(equalToConstant: 32),
      lead.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10),
      lead.centerYAnchor.constraint(equalTo: box.centerYAnchor),
      field.leadingAnchor.constraint(equalTo: lead.trailingAnchor, constant: 8),
      field.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -10),
      field.centerYAnchor.constraint(equalTo: box.centerYAnchor),
    ])
  }

  // MARK: Theme

  func apply(_ palette: ThemePalette) {
    self.palette = palette

    layer?.backgroundColor = palette[.base].cgColor
    hintRule.layer?.backgroundColor = palette[.surface0].cgColor
    filterBox.apply(palette)
    commandBox.apply(palette)

    titleLabel.textColor = palette[.text].nsColor
    subtitleLabel.textColor = palette[.subtext0].nsColor
    magnifier.contentTintColor = palette[.subtext0].nsColor
    commandCaption.textColor = palette[.subtext0].nsColor
    emptyLabel.textColor = palette[.subtext0].nsColor
    hintLabel.textColor = palette[.subtext0].nsColor
    errorLabel.textColor = palette[.red].nsColor

    for (field, placeholder) in [
      (filterField, "Type to filter"), (commandField, "htop or tail -f log"),
    ] {
      field.textColor = palette[.text].nsColor
      field.placeholderAttributedString = NSAttributedString(
        string: placeholder,
        attributes: [
          .foregroundColor: palette[.subtext0].nsColor, .font: field.font as Any,
        ])
    }

    for row in rows { row.apply(palette) }
  }

  // MARK: Rendering

  private func render() {
    let visible = model.visible
    let selected = model.selection?.kind

    for row in rows {
      let at = visible.firstIndex { $0.kind == row.kind }

      row.isHidden = at == nil
      row.keyText = at.map { $0 < 9 ? "\u{2318}\($0 + 1)" : "" } ?? ""
      row.isSelected = row.kind == selected
    }

    commandWrapper.isHidden = !model.showsCommand
    emptyLabel.isHidden = !visible.isEmpty

    errorLabel.stringValue = model.refusal?.reason ?? ""
    errorLabel.isHidden = model.refusal == nil

    if filterField.stringValue != model.filter {
      filterField.stringValue = model.filter
    }

    if commandField.stringValue != model.command {
      commandField.stringValue = model.command
    }
  }

  // MARK: Actions

  /// Whether the keyboard is in one of the launcher's text fields.
  var hasKeyboard: Bool {
    guard let responder = window?.firstResponder as? NSView else { return false }

    return responder.isDescendant(of: self)
  }

  /// Whether the field the model wants the keyboard in has it.
  func isFocused(_ field: NSTextField) -> Bool {
    guard let editor = field.currentEditor() else { return false }

    return window?.firstResponder === editor
  }

  /// Puts the keyboard in the field the selection calls for, with the caret at the end of its text.
  func focusCurrent() {
    guard let window else { return }

    let field = model.focus == .command ? commandField : filterField

    guard !isFocused(field) else { return }

    guard window.makeFirstResponder(field), let editor = field.currentEditor() else { return }

    editor.selectedRange = NSRange(location: (editor.string as NSString).length, length: 0)
  }

  func setFilter(_ text: String) {
    model.filter = text
    render()
  }

  func setCommand(_ text: String) {
    model.command = text
    render()
  }

  /// Selects an entry and moves the keyboard to where it belongs.
  func choose(_ kind: LauncherEntry.Kind) {
    model.select(kind)
    render()
    focusCurrent()
  }

  func moveSelection(by step: Int) {
    model.move(by: step)
    render()
    focusCurrent()
  }

  /// Picks the Nth visible entry. Returns false when there is none.
  @discardableResult
  func pick(number: Int) -> Bool {
    let picked = model.pick(number: number)
    render()
    focusCurrent()
    return picked
  }

  /// Opens the selected entry, or says why it cannot be opened and keeps the launcher.
  func open() {
    guard model.selection != nil else { return }

    switch model.choice() {
    case .failure(let refusal):
      model.refusal = refusal

    case .success(let choice):
      do {
        try onChoose?(choice)
        return
      } catch {
        model.refusal = LauncherRefusal(reason: error.localizedDescription)
      }
    }

    render()
    focusCurrent()
  }

  /// Escape in the command field goes back to the filter with the terminal selected.
  func leaveCommand() {
    model.backToTerminal()
    render()
    focusCurrent()
  }

  /// Escape in the filter closes the empty pane.
  func exit() {
    onExit?()
  }

  // MARK: Keys

  func controlTextDidChange(_ notification: Notification) {
    guard let field = notification.object as? NSTextField else { return }

    if field === filterField {
      setFilter(field.stringValue)
    } else if field === commandField {
      setCommand(field.stringValue)
    }
  }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    switch selector {
    case #selector(NSResponder.moveUp(_:)):
      moveSelection(by: -1)

    case #selector(NSResponder.moveDown(_:)):
      moveSelection(by: 1)

    case #selector(NSResponder.insertNewline(_:)):
      open()

    case #selector(NSResponder.cancelOperation(_:)):
      if control === commandField {
        leaveCommand()
      } else {
        exit()
      }

    default:
      return false
    }

    return true
  }

  /// Command-1 to Command-9 pick an entry while the keyboard is in the launcher. A number past the
  /// last visible entry is taken and ignored, so it never selects a terminal tab by accident.
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard event.type == .keyDown, hasKeyboard,
      event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
      let digit = event.charactersIgnoringModifiers.flatMap({ Int($0) }), (1...9).contains(digit)
    else { return super.performKeyEquivalent(with: event) }

    pick(number: digit)
    return true
  }

  /// A click on bare space returns the keyboard to the field it belongs in.
  override func mouseDown(with event: NSEvent) {
    focusCurrent()
  }
}

extension ThemePalette {
  /// The text color on a row drawn in the accent color. It matches the terminal's cursor text,
  /// which also sits on a solid accent.
  fileprivate var onAccent: ThemeColor {
    flavor == .latte ? self[.base] : self[.crust]
  }
}
