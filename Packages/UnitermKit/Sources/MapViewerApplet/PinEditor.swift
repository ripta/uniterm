import AppKit
import GeoData
import Theme

/// The fields for one pin's label, accent, and glyph, shown in a popover over the pin.
///
/// Nothing changes until Done. Cancel and Escape leave the pin as it was. A glyph the map cannot
/// draw keeps Done off and says why, so the file never gains a value the reader would drop.
@MainActor
final class PinEditorController: NSViewController, NSTextFieldDelegate {
  let original: GeoPin

  /// Gets the edited pin when the user presses Done.
  var onDone: ((GeoPin) -> Void)?

  /// Gets Cancel.
  var onCancel: (() -> Void)?

  let labelField = NSTextField()
  let accentMenu = NSPopUpButton()
  let glyphField = NSTextField()
  let doneButton = NSButton(title: "Done", target: nil, action: nil)
  private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
  private let problem = NSTextField(wrappingLabelWithString: "")

  /// The width of each field. The popover is sized from it, so a long error wraps instead of
  /// widening the popover.
  static let fieldWidth = 240.0
  private let palette: ThemePalette
  private let layerAccent: ThemeToken

  init(pin: GeoPin, layerAccent: ThemeToken, palette: ThemePalette) {
    original = pin
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

    glyphField.stringValue = original.glyph?.text ?? ""
    glyphField.placeholderString = "One or two characters, or a symbol name"
    glyphField.delegate = self
    glyphField.setAccessibilityIdentifier("pin-editor-glyph")
    glyphField.setAccessibilityLabel("Glyph")

    problem.font = .systemFont(ofSize: 11)
    problem.textColor = .systemRed
    problem.isHidden = true

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
      [NSTextField(labelWithString: "Glyph"), glyphField],
    ])
    grid.column(at: 0).xPlacement = .trailing
    grid.rowAlignment = .firstBaseline
    grid.rowSpacing = 10
    grid.columnSpacing = 8

    for field in [labelField, glyphField] {
      field.widthAnchor.constraint(equalToConstant: Self.fieldWidth).isActive = true
    }

    problem.preferredMaxLayoutWidth = Self.fieldWidth

    let buttons = NSStackView(views: [cancelButton, doneButton])
    buttons.spacing = 8

    let stack = NSStackView(views: [grid, problem, buttons])
    stack.orientation = .vertical
    stack.alignment = .trailing
    stack.spacing = 12
    stack.translatesAutoresizingMaskIntoConstraints = false
    problem.widthAnchor.constraint(equalToConstant: Self.fieldWidth).isActive = true

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

  /// The pin as the fields describe it, or nil when the glyph is not one the map can draw.
  var editedPin: GeoPin? {
    let glyphText = glyphField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    var glyph: PinGlyph?

    if !glyphText.isEmpty {
      guard let parsed = PinGlyph(glyphText), Self.canDraw(parsed) else { return nil }

      glyph = parsed
    }

    let accent = (accentMenu.selectedItem?.representedObject as? String).flatMap {
      ThemeToken(accent: $0)
    }

    return GeoPin(
      id: original.id, coordinate: original.coordinate,
      label: labelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
      accent: accent, glyph: glyph)
  }

  /// True for a glyph this Mac can draw. A name shaped like an SF Symbol that the system does not
  /// have would draw as the default dot, so the editor refuses it.
  static func canDraw(_ glyph: PinGlyph) -> Bool {
    guard case .symbol(let name) = glyph else { return true }

    return NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
  }

  func controlTextDidChange(_ notification: Notification) {
    let valid = editedPin != nil
    let typed = glyphField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

    doneButton.isEnabled = valid
    problem.isHidden = valid

    if valid {
      problem.stringValue = ""
    } else if case .symbol(let name)? = PinGlyph(typed) {
      problem.stringValue = "This Mac has no SF Symbol named \u{201C}\(name)\u{201D}."
    } else {
      problem.stringValue =
        "A glyph is one or two characters, or an SF Symbol name such as star.fill."
    }
  }

  @objc func done() {
    guard let pin = editedPin else { return }

    onDone?(pin)
  }

  @objc func cancel() {
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
