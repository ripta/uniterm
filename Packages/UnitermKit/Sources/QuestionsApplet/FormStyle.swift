import AppKit
import Theme

/// Colors the views of one form from the palette. Each view registers a rule when it is built, and
/// a palette change runs every rule again, so no view holds a color the palette does not own.
@MainActor
final class FormStyler {
  private(set) var palette: ThemePalette
  private var rules: [(ThemePalette) -> Void] = []

  init(palette: ThemePalette) {
    self.palette = palette
  }

  /// Runs the rule now and on every palette change.
  func add(_ rule: @escaping (ThemePalette) -> Void) {
    rules.append(rule)
    rule(palette)
  }

  func apply(_ palette: ThemePalette) {
    self.palette = palette

    for rule in rules { rule(palette) }
  }
}

/// The root of one question's widget. It names the question, so the form can tell which field has
/// the keyboard.
final class FieldRootView: NSStackView {
  var questionID = ""
}

/// A view whose origin is at the top, so a scroll view's document starts at its first line.
final class FlippedView: NSView {
  override var isFlipped: Bool { true }
}

/// A push button that still hears a click while it is disabled. A validating button is disabled
/// until the form passes, and a click on it counts as trying to submit.
final class FormPushButton: NSButton {
  var onDisabledClick: (() -> Void)?

  override func mouseDown(with event: NSEvent) {
    guard !isEnabled else {
      super.mouseDown(with: event)

      return
    }

    onDisabledClick?()
  }
}

extension FormStyler {
  /// A label that wraps to the width it is given.
  func wrappingLabel(
    _ text: String, style: NSFont.TextStyle = .body, bold: Bool = false, color: ThemeToken = .text
  ) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)

    label.font = Self.font(style, bold: bold)
    label.isSelectable = true
    label.allowsEditingTextAttributes = false
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    add { palette in label.textColor = palette[color].nsColor }

    return label
  }

  /// A one-line label that never wraps.
  func plainLabel(
    _ text: String, style: NSFont.TextStyle = .body, bold: Bool = false, color: ThemeToken = .text
  ) -> NSTextField {
    let label = NSTextField(labelWithString: text)

    label.font = Self.font(style, bold: bold)
    label.lineBreakMode = .byTruncatingTail

    add { palette in label.textColor = palette[color].nsColor }

    return label
  }

  static func font(_ style: NSFont.TextStyle, bold: Bool) -> NSFont {
    let base = NSFont.preferredFont(forTextStyle: style)

    guard bold else { return base }

    return NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
  }
}

/// Cuts text at a scalar boundary so it holds at most `bytes` UTF-8 bytes.
func clipped(_ text: String, toBytes bytes: Int) -> String {
  guard text.utf8.count > bytes else { return text }

  var kept = ""
  var count = 0

  for scalar in text.unicodeScalars {
    count += String(scalar).utf8.count

    if count > bytes { break }

    kept.unicodeScalars.append(scalar)
  }

  return kept
}
