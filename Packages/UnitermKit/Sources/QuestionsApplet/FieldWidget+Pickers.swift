import AppKit
import QuestionForm
import UniformTypeIdentifiers

// MARK: Color

/// A `color`. The color well opens the system's color panel, and the answer is the chosen sRGB
/// color as `#rrggbbaa`. A question with no default has no answer until the user picks one.
@MainActor
final class ColorField: FieldWidget {
  private let well = NSColorWell(frame: NSRect(x: 0, y: 0, width: 44, height: 26))
  private let value: NSTextField
  private let clearButton = NSButton(title: "Clear", target: nil, action: nil)
  private var chosen: String?
  private var monitor: Any?

  override init(question: FormQuestion, styler: FormStyler) {
    value = styler.plainLabel("", color: .subtext1)

    super.init(question: question, styler: styler)

    if case .text(let text) = FormSession.initialAnswer(question),
      let normalized = FormChecker.normalizedColor(text)
    {
      chosen = normalized
      well.color = Self.color(from: normalized) ?? .systemGray
    } else {
      well.color = .systemGray
    }

    well.translatesAutoresizingMaskIntoConstraints = false
    well.widthAnchor.constraint(equalToConstant: 44).isActive = true
    well.heightAnchor.constraint(equalToConstant: 26).isActive = true
    well.target = self
    well.action = #selector(picked(_:))
    well.setAccessibilityIdentifier("question-\(question.id)")
    well.setAccessibilityLabel(question.text)

    clearButton.isBordered = false
    clearButton.controlSize = .small
    clearButton.target = self
    clearButton.action = #selector(cleared(_:))
    clearButton.setAccessibilityIdentifier("question-\(question.id)-clear")
    clearButton.setAccessibilityLabel("Clear \(question.text)")

    styler.add { [clearButton] palette in
      clearButton.attributedTitle = NSAttributedString(
        string: "Clear",
        attributes: [
          .foregroundColor: palette[.blue].nsColor,
          .font: NSFont.preferredFont(forTextStyle: .caption1),
        ])
    }

    let row = NSStackView(views: [well, value, clearButton])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 8

    root.addArrangedSubview(row)

    // Escape closes the color panel before it cancels the form. The panel is its own window, so
    // its keys never reach the form's view.
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      let isEscape =
        event.keyCode == 53 && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
      let windowNumber = event.windowNumber
      let consumed = MainActor.assumeIsolated {
        self?.closePanelIfOpen(isEscape, in: windowNumber) ?? false
      }

      return consumed ? nil : event
    }

    render()
  }

  override var focusTarget: NSView? { well }

  override func lock() {
    well.isEnabled = false
    clearButton.isEnabled = false
    closePanelNow()
  }

  override func tearDown() {
    if let monitor { NSEvent.removeMonitor(monitor) }

    monitor = nil
    closePanelNow()
  }

  /// Closes the color panel when the key is Escape, this field's color well opened it, and the key
  /// went to the panel or to this form's window. Returns whether the key was used.
  private func closePanelIfOpen(_ isEscape: Bool, in windowNumber: Int) -> Bool {
    guard isEscape, NSColorPanel.sharedColorPanelExists, NSColorPanel.shared.isVisible,
      well.isActive,
      windowNumber == NSColorPanel.shared.windowNumber || windowNumber == well.window?.windowNumber
    else { return false }

    let window = well.window

    closePanelNow()
    window?.makeKeyAndOrderFront(nil)

    return true
  }

  private func closePanelNow() {
    guard NSColorPanel.sharedColorPanelExists, well.isActive else { return }

    well.deactivate()
    NSColorPanel.shared.orderOut(nil)
  }

  private func render() {
    value.stringValue = chosen ?? "No color chosen"
    clearButton.isHidden = question.isRequired || chosen == nil
  }

  @objc private func picked(_ sender: Any?) {
    guard let color = Self.hex(of: well.color) else { return }

    chosen = color

    render()
    onChange(.text(color))
  }

  @objc private func cleared(_ sender: Any?) {
    chosen = nil
    well.color = .systemGray

    render()
    onChange(.unanswered)
  }

  /// The color as `#rrggbbaa` in sRGB, or nil when it has no sRGB form.
  static func hex(of color: NSColor) -> String? {
    guard let srgb = color.usingColorSpace(.sRGB) else { return nil }

    func byte(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }

    return String(
      format: "#%02x%02x%02x%02x", byte(srgb.redComponent), byte(srgb.greenComponent),
      byte(srgb.blueComponent), byte(srgb.alphaComponent))
  }

  static func color(from hex: String) -> NSColor? {
    guard let normalized = FormChecker.normalizedColor(hex) else { return nil }

    let digits = normalized.dropFirst()
    var parts: [CGFloat] = []
    var index = digits.startIndex

    while index < digits.endIndex {
      let next = digits.index(index, offsetBy: 2)

      guard let byte = UInt8(digits[index..<next], radix: 16) else { return nil }

      parts.append(CGFloat(byte) / 255)
      index = next
    }

    return NSColor(srgbRed: parts[0], green: parts[1], blue: parts[2], alpha: parts[3])
  }
}

// MARK: File

/// A `file`. The button opens the system's open or save panel as a sheet on the form's window,
/// and the answer is the chosen paths. The panel runs in the user's own process, so the path is
/// all the script receives.
@MainActor
final class FileField: FieldWidget {
  private let mode: FormFileMode
  private let multiple: Bool
  private let types: [UTType]
  private let summary: NSTextField
  private let chooseButton = NSButton(title: "Choose\u{2026}", target: nil, action: nil)
  private let clearButton = NSButton(title: "Clear", target: nil, action: nil)
  private var paths: [String] = []
  private var cut = 0

  override init(question: FormQuestion, styler: FormStyler) {
    guard case .file(let mode, let multiple, let identifiers) = question.type else {
      preconditionFailure("a file field is built for a file question")
    }

    self.mode = mode
    self.multiple = multiple
    types = identifiers.compactMap { UTType($0) }
    summary = styler.wrappingLabel("", color: .subtext1)

    super.init(question: question, styler: styler)

    chooseButton.title =
      switch mode {
      case .open: multiple ? "Choose files\u{2026}" : "Choose file\u{2026}"
      case .directory: multiple ? "Choose folders\u{2026}" : "Choose folder\u{2026}"
      case .save: "Choose where to save\u{2026}"
      }

    chooseButton.target = self
    chooseButton.action = #selector(choose(_:))
    chooseButton.setAccessibilityIdentifier("question-\(question.id)")
    chooseButton.setAccessibilityLabel(question.text)

    clearButton.isBordered = false
    clearButton.controlSize = .small
    clearButton.target = self
    clearButton.action = #selector(cleared(_:))
    clearButton.setAccessibilityIdentifier("question-\(question.id)-clear")
    clearButton.setAccessibilityLabel("Clear \(question.text)")

    styler.add { [clearButton] palette in
      clearButton.attributedTitle = NSAttributedString(
        string: "Clear",
        attributes: [
          .foregroundColor: palette[.blue].nsColor,
          .font: NSFont.preferredFont(forTextStyle: .caption1),
        ])
    }

    summary.setAccessibilityIdentifier("question-\(question.id)-paths")

    let row = NSStackView(views: [chooseButton, clearButton])
    row.orientation = .horizontal
    row.spacing = 8

    root.addArrangedSubview(row)
    root.addArrangedSubview(summary)
    stretch(summary)

    render()
  }

  override var focusTarget: NSView? { chooseButton }

  override func lock() {
    chooseButton.isEnabled = false
    clearButton.isEnabled = false
  }

  private var answer: FormAnswer {
    guard !paths.isEmpty else { return .unanswered }

    return multiple ? .list(paths) : .text(paths[0])
  }

  private func render() {
    if paths.isEmpty {
      summary.stringValue = mode == .save ? "No place chosen" : "Nothing chosen"
    } else {
      var lines = paths.joined(separator: "\n")

      if cut > 0 {
        lines += "\n\(cut) more not kept. A form takes at most \(question.answerEntryLimit)."
      }

      summary.stringValue = lines
    }

    clearButton.isHidden = question.isRequired || paths.isEmpty
  }

  @objc private func choose(_ sender: Any?) {
    guard let window = root.window else { return }

    let panel: NSSavePanel = mode == .save ? NSSavePanel() : NSOpenPanel()

    panel.canCreateDirectories = true
    panel.message = question.text

    if !types.isEmpty { panel.allowedContentTypes = types }

    if let open = panel as? NSOpenPanel {
      open.canChooseFiles = mode == .open
      open.canChooseDirectories = mode == .directory
      open.allowsMultipleSelection = multiple
    }

    panel.beginSheetModal(for: window) { [weak self, weak panel] response in
      MainActor.assumeIsolated {
        guard response == .OK, let self, let panel else { return }

        let urls = (panel as? NSOpenPanel)?.urls ?? [panel.url].compactMap { $0 }

        self.take(urls.map(\.path))
      }
    }
  }

  /// Records the paths the panel returned, up to what the question takes.
  func take(_ chosen: [String]) {
    let limit = question.answerEntryLimit

    paths = Array(chosen.prefix(limit))
    cut = max(0, chosen.count - limit)

    render()
    onChange(answer)
  }

  @objc private func cleared(_ sender: Any?) {
    paths = []
    cut = 0

    render()
    onChange(.unanswered)
  }
}
