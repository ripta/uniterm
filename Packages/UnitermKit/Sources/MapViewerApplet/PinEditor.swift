import AppKit
import GeoData
import Theme

/// The fields for one pin's label, accent, and glyph, shown in a popover over the pin.
///
/// Nothing changes until Done. Cancel and Escape leave the pin as it was. The glyph comes from the
/// glyph picker, which offers only glyphs the map can draw, so no value the reader would drop
/// reaches the file.
@MainActor
final class PinEditorController: NSViewController {
  let original: GeoPin

  /// Gets the edited pin when the user presses Done.
  var onDone: ((GeoPin) -> Void)?

  /// Gets Cancel.
  var onCancel: (() -> Void)?

  let labelField = NSTextField()
  let accentMenu = NSPopUpButton()
  let glyphButton = NSButton(title: "", target: nil, action: nil)
  let doneButton = NSButton(title: "Done", target: nil, action: nil)
  private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

  /// The glyph Done writes. The picker sets it.
  private(set) var glyph: PinGlyph?

  /// The glyph picker, while it shows.
  private(set) var picker: (popover: NSPopover, controller: GlyphPickerController)?
  private let usedGlyphs: [PinGlyph]

  /// The width of the label field. The popover is sized from it.
  static let fieldWidth = 240.0
  private let palette: ThemePalette
  private let layerAccent: ThemeToken

  /// `used` is the glyphs the file's pins already use, which the picker offers as shortcuts.
  init(pin: GeoPin, layerAccent: ThemeToken, palette: ThemePalette, used: [PinGlyph] = []) {
    original = pin
    glyph = pin.glyph
    usedGlyphs = used
    self.palette = palette
    self.layerAccent = layerAccent

    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  override func loadView() {
    labelField.stringValue = original.label
    labelField.placeholderString = "The coordinate"
    labelField.setAccessibilityIdentifier("pin-editor-label")
    labelField.setAccessibilityLabel("Label")

    accentMenu.addItem(withTitle: "Default")
    accentMenu.lastItem?.image = swatch(layerAccent)
    accentMenu.lastItem?.representedObject = nil

    for accent in ThemeToken.accents {
      accentMenu.addItem(withTitle: accent.rawValue.capitalized)
      accentMenu.lastItem?.image = swatch(accent)
      accentMenu.lastItem?.representedObject = accent.rawValue
    }

    if let accent = original.accent, let index = ThemeToken.accents.firstIndex(of: accent) {
      accentMenu.selectItem(at: index + 1)
    }

    accentMenu.setAccessibilityIdentifier("pin-editor-accent")
    accentMenu.setAccessibilityLabel("Color")

    glyphButton.bezelStyle = .push
    glyphButton.imagePosition = .imageLeading
    glyphButton.target = self
    glyphButton.action = #selector(showPicker)
    glyphButton.setAccessibilityIdentifier("pin-editor-glyph")
    glyphButton.setAccessibilityLabel("Glyph")
    showGlyph()

    doneButton.target = self
    doneButton.action = #selector(done)
    doneButton.keyEquivalent = "\r"
    doneButton.setAccessibilityIdentifier("pin-editor-done")
    cancelButton.target = self
    cancelButton.action = #selector(cancel)
    cancelButton.keyEquivalent = "\u{1B}"

    let grid = NSGridView(views: [
      [NSTextField(labelWithString: "Label"), labelField],
      [NSTextField(labelWithString: "Color"), accentMenu],
      [NSTextField(labelWithString: "Glyph"), glyphButton],
    ])
    grid.column(at: 0).xPlacement = .trailing
    grid.rowAlignment = .firstBaseline
    grid.rowSpacing = 10
    grid.columnSpacing = 8

    labelField.widthAnchor.constraint(equalToConstant: Self.fieldWidth).isActive = true
    grid.cell(for: glyphButton)?.xPlacement = .leading
    grid.cell(for: accentMenu)?.xPlacement = .leading

    let buttons = NSStackView(views: [cancelButton, doneButton])
    buttons.spacing = 8

    let stack = NSStackView(views: [grid, buttons])
    stack.orientation = .vertical
    stack.alignment = .trailing
    stack.spacing = 12
    stack.translatesAutoresizingMaskIntoConstraints = false

    let container = NSView()
    container.setAccessibilityElement(true)
    container.setAccessibilityRole(.group)
    container.setAccessibilityIdentifier("pin-editor")
    container.addSubview(stack)

    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
      stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
      stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
      stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
    ])

    view = container
  }

  /// The pin as the fields describe it.
  var editedPin: GeoPin {
    let accent = (accentMenu.selectedItem?.representedObject as? String).flatMap {
      ThemeToken(accent: $0)
    }

    return GeoPin(
      id: original.id, coordinate: original.coordinate,
      label: labelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
      accent: accent, glyph: glyph)
  }

  // MARK: Glyph

  /// Shows the glyph on the button: the symbol itself and its name, the characters, or None. A
  /// symbol this Mac lacks, from a file, shows its name.
  private func showGlyph() {
    switch glyph {
    case .symbol(let name):
      glyphButton.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
      glyphButton.title = name

    case .text(let text):
      glyphButton.image = nil
      glyphButton.title = text

    case nil:
      glyphButton.image = nil
      glyphButton.title = "None"
    }

    glyphButton.setAccessibilityValue(glyphButton.title)
  }

  @objc func showPicker() {
    closePicker()

    let controller = GlyphPickerController(current: glyph, used: usedGlyphs)
    let popover = NSPopover()
    popover.contentViewController = controller
    popover.behavior = .semitransient

    controller.onPick = { [weak self] picked in self?.choose(picked) }
    picker = (popover, controller)

    if glyphButton.window != nil {
      popover.show(relativeTo: glyphButton.bounds, of: glyphButton, preferredEdge: .maxX)
    }
  }

  /// Takes a glyph from the picker and closes it.
  func choose(_ picked: PinGlyph?) {
    glyph = picked
    showGlyph()
    closePicker()
  }

  private func closePicker() {
    picker?.popover.close()
    picker = nil
  }

  @objc func done() {
    closePicker()
    onDone?(editedPin)
  }

  @objc func cancel() {
    closePicker()
    onCancel?()
  }

  private func swatch(_ accent: ThemeToken) -> NSImage {
    let color = palette[accent].nsColor

    return NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
      color.setFill()
      NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
      return true
    }
  }
}
