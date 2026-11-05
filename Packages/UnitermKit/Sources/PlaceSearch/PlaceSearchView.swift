import AppKit
import GeoData
import Theme

/// One suggestion: the place's name over where it is.
@MainActor
final class PlaceSuggestionRow: NSView {
  let titleLabel = NSTextField(labelWithString: "")
  let subtitleLabel = NSTextField(labelWithString: "")

  var onClick: (() -> Void)?

  var isHighlighted = false {
    didSet { restyle() }
  }

  private var palette = ThemePalette.latte

  override var isFlipped: Bool { true }

  init() {
    super.init(frame: .zero)

    wantsLayer = true
    layer?.cornerRadius = 6

    titleLabel.font = .systemFont(ofSize: 13)
    subtitleLabel.font = .systemFont(ofSize: 11)

    for label in [titleLabel, subtitleLabel] {
      label.lineBreakMode = .byTruncatingTail
      label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    let stack = NSStackView(views: [titleLabel, subtitleLabel])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 1
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)

    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
      stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
      stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
    ])

    setAccessibilityElement(true)
    setAccessibilityRole(.button)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  func show(_ suggestion: PlaceSuggestion) {
    titleLabel.stringValue = suggestion.title
    subtitleLabel.stringValue = suggestion.subtitle
    subtitleLabel.isHidden = suggestion.subtitle.isEmpty

    let label =
      suggestion.subtitle.isEmpty ? suggestion.title : "\(suggestion.title), \(suggestion.subtitle)"
    setAccessibilityLabel(label)
  }

  func apply(_ palette: ThemePalette) {
    self.palette = palette
    restyle()
  }

  private func restyle() {
    layer?.backgroundColor = isHighlighted ? palette[.surface0].cgColor : NSColor.clear.cgColor
    titleLabel.textColor = palette[.text].nsColor
    subtitleLabel.textColor = palette[.subtext0].nsColor
    setAccessibilityValue(isHighlighted ? "selected" : "")
  }

  override func mouseDown(with event: NSEvent) {
    onClick?()
  }

  override func accessibilityPerformPress() -> Bool {
    onClick?()
    return true
  }
}

/// A field that searches for a place as the user types, with the suggestions under it.
///
/// The launcher and the map both show it, so a place is found the same way from either. The view
/// owns its model and its searcher. It never moves a map itself. `onPick` gets the region the
/// chosen place covers.
///
/// Up and Down move the highlight, Return picks the highlighted place, and Escape empties the
/// field. A key the field has no use for goes to the owner's callbacks, so the launcher can use
/// Up and Down for its own list and Return for opening a map with no place.
@MainActor
public final class PlaceSearchView: NSView, NSTextFieldDelegate {
  /// Gets the region of the place the user picked, and the suggestion it came from.
  public var onPick: ((GeoRegion, PlaceSuggestion) -> Void)?

  /// Gets Return on an empty field, or Command-Return on any field.
  public var onSubmitWithoutPlace: (() -> Void)?

  /// Gets Escape on an empty field.
  public var onEscapeEmpty: (() -> Void)?

  /// Gets Up or Down when there are no suggestions to move through. Returns true when it used it.
  public var onMoveOut: ((Int) -> Bool)?

  public let field = NSTextField()
  public private(set) var model = PlaceSearchModel()

  private let searcher: any PlaceSearching
  private let box = NSView()
  private let icon = NSImageView()
  private let list = NSStackView()
  private let messageLabel = NSTextField(wrappingLabelWithString: "")
  private var rows: [PlaceSuggestionRow] = []
  private var picking: Task<Void, Never>?
  private var palette = ThemePalette.latte

  public override var isFlipped: Bool { true }

  public init(searcher: any PlaceSearching, placeholder: String) {
    self.searcher = searcher
    super.init(frame: .zero)

    build(placeholder: placeholder)

    searcher.onUpdate = { [weak self] result in self?.receive(result) }

    apply(.latte)
    render()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  private func build(placeholder: String) {
    icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
    icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.setContentHuggingPriority(.required, for: .horizontal)

    field.font = .systemFont(ofSize: 13)
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.usesSingleLineMode = true
    field.cell?.isScrollable = true
    field.placeholderString = placeholder
    field.delegate = self
    field.translatesAutoresizingMaskIntoConstraints = false
    field.setAccessibilityIdentifier("place-search-field")
    field.setAccessibilityLabel("Place")

    box.wantsLayer = true
    box.layer?.cornerRadius = 8
    box.layer?.borderWidth = 1
    box.translatesAutoresizingMaskIntoConstraints = false
    box.addSubview(icon)
    box.addSubview(field)

    list.orientation = .vertical
    list.alignment = .leading
    list.spacing = 1
    list.translatesAutoresizingMaskIntoConstraints = false
    list.setAccessibilityElement(true)
    list.setAccessibilityRole(.list)
    list.setAccessibilityIdentifier("place-suggestions")
    list.setAccessibilityLabel("Places")

    messageLabel.font = .systemFont(ofSize: 11)
    messageLabel.translatesAutoresizingMaskIntoConstraints = false
    messageLabel.setAccessibilityIdentifier("place-search-message")

    let stack = NSStackView(views: [box, list, messageLabel])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 4
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)

    for view in [box, list, messageLabel] {
      view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor),
      box.heightAnchor.constraint(equalToConstant: 32),
      icon.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10),
      icon.centerYAnchor.constraint(equalTo: box.centerYAnchor),
      field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
      field.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -10),
      field.centerYAnchor.constraint(equalTo: box.centerYAnchor),
    ])

    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityIdentifier("place-search")
    setAccessibilityLabel("Go to place")
  }

  // MARK: Theme

  public func apply(_ palette: ThemePalette) {
    self.palette = palette

    box.layer?.backgroundColor = palette[.mantle].cgColor
    box.layer?.borderColor = palette[.blue].cgColor
    icon.contentTintColor = palette[.subtext0].nsColor
    field.textColor = palette[.text].nsColor
    field.placeholderAttributedString = NSAttributedString(
      string: field.placeholderString ?? "",
      attributes: [.foregroundColor: palette[.subtext0].nsColor, .font: field.font as Any])
    messageLabel.textColor = palette[.subtext0].nsColor

    for row in rows { row.apply(palette) }
  }

  // MARK: State

  /// Puts the keyboard in the field, with the caret at the end.
  public func focusField() {
    guard let window else { return }

    if let editor = field.currentEditor(), window.firstResponder === editor { return }

    guard window.makeFirstResponder(field), let editor = field.currentEditor() else { return }

    editor.selectedRange = NSRange(location: (editor.string as NSString).length, length: 0)
  }

  /// Whether the keyboard is in the field.
  public var hasKeyboard: Bool {
    guard let editor = field.currentEditor() else { return false }

    return window?.firstResponder === editor
  }

  /// Empties the field and drops a pick in flight.
  public func reset() {
    picking?.cancel()
    picking = nil
    model.clear()
    field.stringValue = ""
    searcher.search("")
    render()
  }

  /// Stops the searcher. The owner calls it when the view goes away for good.
  public func stop() {
    picking?.cancel()
    picking = nil
    searcher.cancel()
  }

  func setQuery(_ text: String) {
    if model.setQuery(text) {
      searcher.search(text)
    } else if model.trimmedQuery.isEmpty {
      searcher.search("")
    }

    render()
  }

  private func receive(_ result: Result<[PlaceSuggestion], PlaceSearchFailure>) {
    model.receive(result)
    render()
  }

  /// Finds the highlighted place's region, then hands it to `onPick`.
  func pickHighlighted() {
    guard let suggestion = model.pick() else {
      render()
      return
    }

    render()

    picking = Task { [weak self] in
      guard let self else { return }

      let result = await searcher.region(for: suggestion)

      guard !Task.isCancelled else { return }

      picking = nil

      switch result {
      case .success(let region):
        onPick?(region, suggestion)

      case .failure(let failure):
        model.pickFailed(failure)
        render()
      }
    }
  }

  /// The pick in flight, for a test to wait on.
  var pendingPick: Task<Void, Never>? { picking }

  private func render() {
    while rows.count < model.suggestions.count {
      let row = PlaceSuggestionRow()
      let index = rows.count
      row.apply(palette)
      row.setAccessibilityIdentifier("place-suggestion-\(index)")
      row.onClick = { [weak self] in
        self?.model.highlight(index)
        self?.pickHighlighted()
      }
      rows.append(row)
      list.addArrangedSubview(row)
      row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
    }

    for (index, row) in rows.enumerated() {
      if index < model.suggestions.count {
        row.show(model.suggestions[index])
        row.isHidden = false
        row.isHighlighted = index == model.highlighted
      } else {
        row.isHidden = true
      }
    }

    list.isHidden = model.suggestions.isEmpty
    messageLabel.stringValue = model.message ?? ""
    messageLabel.isHidden = model.message == nil
  }

  // MARK: Keys

  public func controlTextDidChange(_ notification: Notification) {
    setQuery(field.stringValue)
  }

  public func control(
    _ control: NSControl, textView: NSTextView, doCommandBy selector: Selector
  ) -> Bool {
    let commandHeld = NSApp.currentEvent?.modifierFlags.contains(.command) == true

    switch selector {
    case #selector(NSResponder.moveUp(_:)):
      if model.move(by: -1) { render() } else { return onMoveOut?(-1) ?? false }

    case #selector(NSResponder.moveDown(_:)):
      if model.move(by: 1) { render() } else { return onMoveOut?(1) ?? false }

    case #selector(NSResponder.insertNewline(_:)):
      if commandHeld || model.trimmedQuery.isEmpty {
        onSubmitWithoutPlace?()
      } else {
        pickHighlighted()
      }

    case #selector(NSResponder.cancelOperation(_:)):
      if model.query.isEmpty {
        onEscapeEmpty?()
      } else {
        reset()
      }

    default:
      return false
    }

    return true
  }
}
