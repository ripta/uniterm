import AppKit
import GeoData

/// The SF Symbols the glyph picker offers, by group. Every name exists on macOS 26, and a test
/// holds the list to that.
enum GlyphCatalog {
  static let groups: [(title: String, names: [String])] = [
    (
      "Places",
      [
        "house.fill", "building.2.fill", "briefcase.fill", "graduationcap.fill",
        "building.columns.fill", "cross.case.fill", "cart.fill", "bag.fill",
      ]
    ),
    (
      "Food and drink",
      [
        "fork.knife", "cup.and.saucer.fill", "mug.fill", "wineglass.fill", "birthday.cake.fill",
        "takeoutbag.and.cup.and.straw.fill", "carrot.fill", "fish.fill",
      ]
    ),
    (
      "Travel",
      [
        "airplane", "car.fill", "tram.fill", "bus.fill", "ferry.fill", "bicycle", "fuelpump.fill",
        "parkingsign",
      ]
    ),
    (
      "Outdoors and fun",
      [
        "tree.fill", "leaf.fill", "mountain.2.fill", "beach.umbrella.fill", "tent.fill",
        "figure.hiking", "camera.fill", "ticket.fill",
      ]
    ),
    (
      "Marks",
      [
        "star.fill", "heart.fill", "flag.fill", "pin.fill", "exclamationmark.triangle.fill",
        "questionmark", "checkmark", "bed.double.fill",
      ]
    ),
  ]

  /// The groups with only the names that hold `filter`, ignoring case. An empty filter keeps all.
  /// A name's dots count as spaces, so "coffee cup" finds nothing and "cup" finds the cup.
  static func groups(matching filter: String) -> [(title: String, names: [String])] {
    let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !needle.isEmpty else { return groups }

    return groups.compactMap { group in
      let names = group.names.filter {
        $0.replacingOccurrences(of: ".", with: " ").localizedCaseInsensitiveContains(needle)
      }

      return names.isEmpty ? nil : (group.title, names)
    }
  }
}

/// The glyph picker: a grid of SF Symbols, or one or two characters, shown in a popover from the
/// pin editor's Glyph button.
///
/// Nothing here can make a glyph the map cannot draw. The grid holds only symbols this Mac has,
/// and the character field keeps at most two characters.
@MainActor
final class GlyphPickerController: NSViewController, NSSearchFieldDelegate, NSTextFieldDelegate {
  /// Gets the glyph the user picked, or nil for No Glyph.
  var onPick: ((PinGlyph?) -> Void)?

  let tabs = NSSegmentedControl(
    labels: ["Symbols", "Characters"], trackingMode: .selectOne, target: nil, action: nil)
  let filterField = NSSearchField()
  let noGlyphButton = NSButton(title: "No Glyph", target: nil, action: nil)
  let characterField = NSTextField()
  let characterViewerButton = NSButton(title: "Emoji & Symbols\u{2026}", target: nil, action: nil)
  private let symbolPane = NSStackView()

  /// The scrolling area that holds the symbol groups. Its height is set once, for the whole
  /// catalog, so a filter removes tiles in place and the popover never changes size.
  let symbolArea = NSScrollView()
  let groupsStack = NSStackView()
  private let characterPane = NSStackView()
  private let usedRow = NSStackView()
  private let current: PinGlyph?
  private let usedGlyphs: [PinGlyph]

  /// The symbol tiles shown now, by name. A test presses them.
  private(set) var tiles: [String: NSButton] = [:]

  static let width = 540.0

  /// `used` is the character glyphs already in the file, offered as a shortcut.
  init(current: PinGlyph?, used: [PinGlyph]) {
    self.current = current
    usedGlyphs = used

    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  override func loadView() {
    tabs.target = self
    tabs.action = #selector(tabChanged)
    tabs.setAccessibilityIdentifier("glyph-picker-tabs")

    filterField.placeholderString = "Filter, such as coffee"
    filterField.delegate = self
    filterField.setAccessibilityIdentifier("glyph-picker-filter")

    noGlyphButton.target = self
    noGlyphButton.action = #selector(pickNone)
    noGlyphButton.setAccessibilityIdentifier("glyph-picker-none")

    let header = NSStackView(views: [tabs, filterField, noGlyphButton])
    header.spacing = 8

    groupsStack.orientation = .vertical
    groupsStack.alignment = .leading
    groupsStack.spacing = 10

    let document = FlippedView()
    document.translatesAutoresizingMaskIntoConstraints = false
    groupsStack.translatesAutoresizingMaskIntoConstraints = false
    document.addSubview(groupsStack)

    symbolArea.documentView = document
    symbolArea.hasVerticalScroller = true
    symbolArea.drawsBackground = false
    symbolArea.borderType = .noBorder
    symbolArea.translatesAutoresizingMaskIntoConstraints = false

    NSLayoutConstraint.activate([
      groupsStack.topAnchor.constraint(equalTo: document.topAnchor),
      groupsStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
      groupsStack.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor),
      groupsStack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
      document.topAnchor.constraint(equalTo: symbolArea.contentView.topAnchor),
      document.leadingAnchor.constraint(equalTo: symbolArea.contentView.leadingAnchor),
      document.trailingAnchor.constraint(equalTo: symbolArea.contentView.trailingAnchor),
    ])

    symbolPane.orientation = .vertical
    symbolPane.alignment = .leading
    symbolPane.addArrangedSubview(symbolArea)
    symbolArea.widthAnchor.constraint(equalTo: symbolPane.widthAnchor).isActive = true

    buildCharacterPane()

    let stack = NSStackView(views: [header, symbolPane, characterPane])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 12
    stack.translatesAutoresizingMaskIntoConstraints = false

    let container = NSView()
    container.setAccessibilityElement(true)
    container.setAccessibilityRole(.group)
    container.setAccessibilityIdentifier("glyph-picker")
    container.addSubview(stack)

    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
      stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
      stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
      stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
      container.widthAnchor.constraint(equalToConstant: Self.width),
    ])

    view = container

    let startsOnCharacters: Bool

    if case .text = current { startsOnCharacters = true } else { startsOnCharacters = false }

    renderSymbols()

    // The full catalog sets the area's height, so later filters only empty it.
    groupsStack.layoutSubtreeIfNeeded()
    symbolArea.heightAnchor.constraint(equalToConstant: groupsStack.fittingSize.height).isActive =
      true
    symbolPane.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

    tabs.selectedSegment = startsOnCharacters ? 1 : 0
    showPane()
  }

  // MARK: Symbols

  private func renderSymbols() {
    for view in groupsStack.arrangedSubviews { view.removeFromSuperview() }

    tiles = [:]

    for group in GlyphCatalog.groups(matching: filterField.stringValue) {
      let title = NSTextField(labelWithString: group.title.uppercased())
      title.font = .systemFont(ofSize: 10, weight: .semibold)
      title.textColor = .secondaryLabelColor

      let grid = NSGridView(numberOfColumns: 8, rows: 0)
      grid.rowSpacing = 4
      grid.columnSpacing = 4

      var row: [NSView] = []

      for name in group.names {
        row.append(tile(name))

        if row.count == 8 {
          grid.addRow(with: row)
          row = []
        }
      }

      if !row.isEmpty {
        grid.addRow(with: row + Array(repeating: NSGridCell.emptyContentView, count: 8 - row.count))
      }

      let section = NSStackView(views: [title, grid])
      section.orientation = .vertical
      section.alignment = .leading
      section.spacing = 4
      groupsStack.addArrangedSubview(section)
    }

    if tiles.isEmpty {
      let none = NSTextField(labelWithString: "No symbols match.")
      none.textColor = .secondaryLabelColor
      groupsStack.addArrangedSubview(none)
    }
  }

  private func tile(_ name: String) -> NSButton {
    let button = NSButton(title: "", target: self, action: #selector(pickSymbol(_:)))
    button.image = NSImage(systemSymbolName: name, accessibilityDescription: name)?
      .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold))
    button.imagePosition = .imageOnly
    button.bezelStyle = .flexiblePush
    button.setButtonType(.pushOnPushOff)
    button.toolTip = name
    button.identifier = NSUserInterfaceItemIdentifier(name)
    button.setAccessibilityLabel(name)
    button.state = current == .symbol(name) ? .on : .off
    button.widthAnchor.constraint(equalToConstant: 58).isActive = true
    button.heightAnchor.constraint(equalToConstant: 40).isActive = true
    tiles[name] = button

    return button
  }

  @objc func pickSymbol(_ sender: NSButton) {
    guard let name = sender.identifier?.rawValue, let glyph = PinGlyph(name) else { return }

    onPick?(glyph)
  }

  @objc func pickNone() {
    onPick?(nil)
  }

  // MARK: Characters

  private func buildCharacterPane() {
    if case .text(let text) = current { characterField.stringValue = text }

    characterField.font = .systemFont(ofSize: 16, weight: .bold)
    characterField.alignment = .center
    characterField.placeholderString = "A1"
    characterField.delegate = self
    characterField.setAccessibilityIdentifier("glyph-picker-characters")
    characterField.setAccessibilityLabel("One or two characters")
    characterField.widthAnchor.constraint(equalToConstant: 70).isActive = true

    characterViewerButton.target = self
    characterViewerButton.action = #selector(openCharacterViewer)
    characterViewerButton.setAccessibilityIdentifier("glyph-picker-emoji")

    let use = NSButton(title: "Use", target: self, action: #selector(useCharacters))
    use.keyEquivalent = "\r"
    use.setAccessibilityIdentifier("glyph-picker-use")

    let entry = NSStackView(views: [
      NSTextField(labelWithString: "One or two characters"), characterField, characterViewerButton,
      use,
    ])
    entry.spacing = 8

    characterPane.orientation = .vertical
    characterPane.alignment = .leading
    characterPane.spacing = 10
    characterPane.addArrangedSubview(entry)

    let texts = usedGlyphs.compactMap { glyph -> String? in
      if case .text(let text) = glyph { return text }
      return nil
    }

    if !texts.isEmpty {
      let title = NSTextField(labelWithString: "USED IN THIS FILE")
      title.font = .systemFont(ofSize: 10, weight: .semibold)
      title.textColor = .secondaryLabelColor
      usedRow.spacing = 6

      for text in texts.prefix(12) {
        let button = NSButton(title: text, target: self, action: #selector(pickUsed(_:)))
        button.font = .systemFont(ofSize: 15, weight: .bold)
        button.bezelStyle = .flexiblePush
        usedRow.addArrangedSubview(button)
      }

      characterPane.addArrangedSubview(title)
      characterPane.addArrangedSubview(usedRow)
    }
  }

  /// Keeps the field to two characters. A third replaces what was there, so typing on always
  /// gives the last character typed.
  func controlTextDidChange(_ notification: Notification) {
    if (notification.object as? NSSearchField) === filterField {
      renderSymbols()
      return
    }

    let text = characterField.stringValue

    if text.count > 2 { characterField.stringValue = String(text.suffix(1)) }
  }

  @objc func useCharacters() {
    let text = characterField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

    onPick?(text.isEmpty ? nil : PinGlyph(text))
  }

  @objc private func pickUsed(_ sender: NSButton) {
    onPick?(PinGlyph(sender.title))
  }

  /// Opens the Mac's Emoji and Symbols viewer, which types into the character field.
  @objc private func openCharacterViewer() {
    view.window?.makeFirstResponder(characterField)
    NSApp.orderFrontCharacterPalette(nil)
  }

  // MARK: Tabs

  @objc private func tabChanged() {
    showPane()
  }

  private func showPane() {
    let symbols = tabs.selectedSegment == 0

    symbolPane.isHidden = !symbols
    filterField.isHidden = !symbols
    characterPane.isHidden = symbols

    if !symbols { view.window?.makeFirstResponder(characterField) }

    view.layoutSubtreeIfNeeded()
    preferredContentSize = view.fittingSize
  }

  /// Shows the Characters tab, as a click on it does. A test calls it.
  func showCharacters() {
    tabs.selectedSegment = 1
    showPane()
  }
}

/// A view whose origin is at its top, so a scroll view's content starts at the top.
private final class FlippedView: NSView {
  override var isFlipped: Bool { true }
}
