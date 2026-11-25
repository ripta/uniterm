import AppKit
import QuestionForm
import Theme

/// The control or controls that collect one question's answer.
///
/// A widget reports each change as a `FormAnswer` and never checks it. The form's session checks.
/// Each widget enforces the caps the spec reader computed for its question, so the user cannot
/// enter an answer the script's reply could not carry.
@MainActor
class FieldWidget: NSObject {
  let question: FormQuestion
  let styler: FormStyler

  /// The widget's controls, in a stack that names the question.
  let root = FieldRootView()

  var onChange: (FormAnswer) -> Void = { _ in }

  /// The user pressed Return in a one-line field.
  var onReturn: () -> Void = {}

  /// The user pressed Escape in a field.
  var onEscape: () -> Void = {}

  /// The widget's Tab stops changed, such as a radio group's stop moving to a new selection.
  var onKeyViewsChange: () -> Void = {}

  init(question: FormQuestion, styler: FormStyler) {
    self.question = question
    self.styler = styler

    super.init()

    root.orientation = .vertical
    root.alignment = .leading
    root.spacing = 6
    root.questionID = question.id
    root.translatesAutoresizingMaskIntoConstraints = false
  }

  /// The control that takes the keyboard first.
  var focusTarget: NSView? { nil }

  /// The widget's Tab stops, in reading order. The form chains them with the other questions'.
  ///
  /// A stop the user cannot reach now, such as a hidden Clear button, stays in the list. AppKit
  /// skips a view that cannot become the key view.
  var keyViews: [NSView] { focusTarget.map { [$0] } ?? [] }

  /// The form was answered, so the controls stop taking input.
  func lock() {}

  /// Releases anything outside the view tree, such as an event monitor.
  func tearDown() {}

  /// Makes `view` as wide as the widget, so a field stretches to the form's width.
  func stretch(_ view: NSView) {
    view.translatesAutoresizingMaskIntoConstraints = false
    view.trailingAnchor.constraint(equalTo: root.trailingAnchor).isActive = true
  }

  static func make(_ question: FormQuestion, styler: FormStyler) -> FieldWidget {
    switch question.type {
    case .boolean:
      return BooleanField(question: question, styler: styler)

    case .choice:
      return ChoiceField(question: question, styler: styler)

    case .multi:
      return MultiField(question: question, styler: styler)

    case .string, .integer, .number:
      return TextLineField(question: question, styler: styler)

    case .text(let multiline, _):
      return multiline
        ? TextAreaField(question: question, styler: styler)
        : TextLineField(question: question, styler: styler)

    case .color:
      return ColorField(question: question, styler: styler)

    case .file:
      return FileField(question: question, styler: styler)
    }
  }
}

// MARK: One line of text

/// A one-line field for `string`, a single-line `text`, `integer`, and `number`. A number stays
/// the text the user typed, so the check compares it as a decimal.
@MainActor
final class TextLineField: FieldWidget, NSTextFieldDelegate {
  /// The longest number the field takes, in bytes. A literal has at most 20 digits and an exponent.
  private static let numberBytes = 48

  private let field = NSTextField()
  private let byteLimit: Int
  private let isNumber: Bool

  override init(question: FormQuestion, styler: FormStyler) {
    switch question.type {
    case .integer, .number:
      isNumber = true
      byteLimit = Self.numberBytes

    default:
      isNumber = false
      byteLimit = question.answerByteLimit
    }

    super.init(question: question, styler: styler)

    if case .text(let text) = FormSession.initialAnswer(question) {
      field.stringValue = text
    } else if case .number(let literal) = FormSession.initialAnswer(question) {
      field.stringValue = literal
    }

    field.placeholderString = question.placeholder
    field.delegate = self
    field.usesSingleLineMode = true
    field.lineBreakMode = .byTruncatingTail
    field.cell?.isScrollable = true
    field.setAccessibilityIdentifier("question-\(question.id)")
    field.setAccessibilityLabel(question.text)

    root.addArrangedSubview(field)
    stretch(field)
  }

  override var focusTarget: NSView? { field }

  override func lock() {
    field.isEnabled = false
  }

  /// What the field holds as an answer: nothing when it is empty.
  private var answer: FormAnswer {
    let text = field.stringValue

    if isNumber {
      let trimmed = text.trimmingCharacters(in: .whitespaces)

      return trimmed.isEmpty ? .unanswered : .number(trimmed)
    }

    return text.isEmpty ? .unanswered : .text(text)
  }

  func controlTextDidChange(_ notification: Notification) {
    let text = field.stringValue

    if text.utf8.count > byteLimit {
      let cut = clipped(text, toBytes: byteLimit)

      if let editor = notification.userInfo?["NSFieldEditor"] as? NSTextView {
        editor.string = cut
      }

      field.stringValue = cut
    }

    onChange(answer)
  }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    switch selector {
    case #selector(NSResponder.insertNewline(_:)):
      onReturn()
      return true

    case #selector(NSResponder.cancelOperation(_:)):
      onEscape()
      return true

    default:
      return false
    }
  }
}

// MARK: Several lines of text

/// The text view of a multiline field. Return inserts a newline, as in any text view. Tab leaves
/// the field, and Escape reaches the form.
@MainActor
final class AreaTextView: NSTextView {
  var onEscape: (() -> Void)?

  override func insertTab(_ sender: Any?) {
    window?.selectNextKeyView(self)
  }

  override func insertBacktab(_ sender: Any?) {
    window?.selectPreviousKeyView(self)
  }

  override func cancelOperation(_ sender: Any?) {
    onEscape?()
  }
}

/// A hint that lets every click through to the text under it.
final class HintLabel: NSTextField {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
final class TextAreaField: FieldWidget, NSTextViewDelegate {
  private let scroll = NSScrollView()
  private let textView = AreaTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 96))
  private let hint = HintLabel(labelWithString: "")
  private let byteLimit: Int

  override init(question: FormQuestion, styler: FormStyler) {
    byteLimit = question.answerByteLimit

    super.init(question: question, styler: styler)

    textView.minSize = NSSize(width: 0, height: 0)
    textView.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.textContainer?.widthTracksTextView = true
    textView.textContainerInset = NSSize(width: 4, height: 6)
    textView.isRichText = false
    textView.allowsUndo = true
    textView.font = NSFont.preferredFont(forTextStyle: .body)
    textView.textColor = .textColor
    textView.backgroundColor = .textBackgroundColor
    textView.delegate = self
    textView.onEscape = { [weak self] in self?.onEscape() }
    textView.setAccessibilityIdentifier("question-\(question.id)")
    textView.setAccessibilityLabel(question.text)

    if case .text(let text) = FormSession.initialAnswer(question) {
      textView.string = text
    }

    hint.stringValue = question.placeholder ?? ""
    hint.font = textView.font
    hint.textColor = .placeholderTextColor
    hint.frame = NSRect(x: 9, y: 6, width: 280, height: 18)
    hint.autoresizingMask = [.width]
    hint.lineBreakMode = .byTruncatingTail
    textView.addSubview(hint)

    scroll.documentView = textView
    scroll.hasVerticalScroller = true
    scroll.borderType = .bezelBorder
    scroll.heightAnchor.constraint(equalToConstant: 96).isActive = true

    root.addArrangedSubview(scroll)
    stretch(scroll)

    refreshHint()
  }

  override var focusTarget: NSView? { textView }

  override func lock() {
    textView.isEditable = false
  }

  private func refreshHint() {
    hint.isHidden = !textView.string.isEmpty
  }

  func textView(
    _ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?
  ) -> Bool {
    guard let replacement = replacementString else { return true }

    let current = textView.string as NSString
    let result = current.replacingCharacters(in: range, with: replacement)

    return result.utf8.count <= byteLimit
  }

  func textDidChange(_ notification: Notification) {
    refreshHint()

    let text = textView.string

    onChange(text.isEmpty ? .unanswered : .text(text))
  }
}

// MARK: Yes or no

/// A checkbox. A question with no default has a third state, shown as a dash, that stands for no
/// answer. A question with a default has two states.
@MainActor
final class BooleanField: FieldWidget {
  private let box = NSButton(checkboxWithTitle: "", target: nil, action: nil)
  private let state: NSTextField
  private let allowsNoAnswer: Bool

  override init(question: FormQuestion, styler: FormStyler) {
    if case .boolean(let value) = question.type {
      allowsNoAnswer = value == nil
    } else {
      allowsNoAnswer = true
    }

    state = styler.plainLabel("", color: .subtext1)

    super.init(question: question, styler: styler)

    box.allowsMixedState = allowsNoAnswer
    box.target = self
    box.action = #selector(toggled(_:))
    box.setAccessibilityIdentifier("question-\(question.id)")
    box.setAccessibilityLabel(question.text)

    switch FormSession.initialAnswer(question) {
    case .boolean(let value): box.state = value ? .on : .off
    default: box.state = allowsNoAnswer ? .mixed : .off
    }

    let row = NSStackView(views: [box, state])
    row.orientation = .horizontal
    row.spacing = 6

    root.addArrangedSubview(row)

    refreshState()
  }

  override var focusTarget: NSView? { box }

  override func lock() {
    box.isEnabled = false
  }

  private var answer: FormAnswer {
    switch box.state {
    case .on: return .boolean(true)
    case .off: return .boolean(false)
    default: return .unanswered
    }
  }

  private func refreshState() {
    switch box.state {
    case .on: state.stringValue = "Yes"
    case .off: state.stringValue = "No"
    default: state.stringValue = "Not answered"
    }
  }

  @objc private func toggled(_ sender: Any?) {
    refreshState()
    onChange(answer)
  }
}

// MARK: One of several

/// A `choice`. A few choices show as radio buttons, and more show in a pop-up. `other` adds a
/// free-text entry either way.
@MainActor
final class ChoiceField: FieldWidget, NSTextFieldDelegate {
  /// The most choices that show as radio buttons, `other` included. The thresholds are not part of
  /// the contract. Only the answer's shape is.
  static let radioLimit = 5

  private enum Selection: Equatable {
    case none
    case choice(Int)
    case other
  }

  private let choices: [String]
  private let allowsOther: Bool
  private let usesRadios: Bool
  private var selection = Selection.none

  private var radios: [NSButton] = []
  private let otherRadio = NSButton(radioButtonWithTitle: "Other", target: nil, action: nil)
  private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
  private let otherField = NSTextField()
  private let clearButton = NSButton(title: "Clear", target: nil, action: nil)
  private let hasPlaceholderItem: Bool

  override init(question: FormQuestion, styler: FormStyler) {
    guard case .choice(let choices, let allowsOther, let defaultValue) = question.type else {
      preconditionFailure("a choice field is built for a choice question")
    }

    self.choices = choices
    self.allowsOther = allowsOther
    usesRadios = choices.count + (allowsOther ? 1 : 0) <= Self.radioLimit
    hasPlaceholderItem = defaultValue == nil || !question.isRequired

    super.init(question: question, styler: styler)

    if let defaultValue {
      if let index = choices.firstIndex(of: defaultValue) {
        selection = .choice(index)
      } else {
        selection = .other
        otherField.stringValue = defaultValue
      }
    }

    otherField.placeholderString = "Type your own answer"
    otherField.delegate = self
    otherField.usesSingleLineMode = true
    otherField.setAccessibilityIdentifier("question-\(question.id)-other")
    otherField.setAccessibilityLabel("\(question.text), other")

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

    if usesRadios { buildRadios() } else { buildPopup() }

    root.addArrangedSubview(otherRow)
    root.addArrangedSubview(clearButton)

    render()
  }

  private lazy var otherRow: NSStackView = {
    let row: NSStackView

    if usesRadios {
      row = NSStackView(views: [otherRadio, otherField])
    } else {
      row = NSStackView(views: [otherField])
    }

    row.orientation = .horizontal
    row.spacing = 8
    row.isHidden = !allowsOther

    return row
  }()

  private func buildRadios() {
    let column = NSStackView()
    column.orientation = .vertical
    column.alignment = .leading
    column.spacing = 4

    for (index, choice) in choices.enumerated() {
      let radio = NSButton(
        radioButtonWithTitle: choice, target: self, action: #selector(picked(_:)))
      radio.tag = index
      radio.setAccessibilityIdentifier("question-\(question.id)-choice-\(index)")

      radios.append(radio)
      column.addArrangedSubview(radio)
    }

    otherRadio.target = self
    otherRadio.action = #selector(pickedOther(_:))
    otherRadio.tag = choices.count
    otherRadio.setAccessibilityIdentifier("question-\(question.id)-choice-other")

    root.addArrangedSubview(column)
  }

  private func buildPopup() {
    if hasPlaceholderItem { popup.addItem(withTitle: "Choose\u{2026}") }

    popup.addItems(withTitles: choices)

    if allowsOther {
      popup.menu?.addItem(.separator())
      popup.addItem(withTitle: "Other\u{2026}")
    }

    popup.target = self
    popup.action = #selector(popupChanged(_:))
    popup.setAccessibilityIdentifier("question-\(question.id)")
    popup.setAccessibilityLabel(question.text)

    root.addArrangedSubview(popup)
  }

  override var focusTarget: NSView? {
    usesRadios ? (radios.first { $0.state == .on } ?? radios.first ?? otherRadio) : popup
  }

  /// The radio group is one stop, as in any Mac form: the selected radio, or the first when none
  /// is.
  override var keyViews: [NSView] {
    let group = radios + (allowsOther ? [otherRadio] : [])
    let lead: NSView =
      usesRadios ? (group.first { $0.state == .on } ?? group.first ?? popup) : popup

    return [lead] + (allowsOther ? [otherField] : []) + [clearButton]
  }

  override func lock() {
    for radio in radios { radio.isEnabled = false }

    otherRadio.isEnabled = false
    popup.isEnabled = false
    otherField.isEnabled = false
    clearButton.isEnabled = false
  }

  private var answer: FormAnswer {
    switch selection {
    case .none:
      return .unanswered

    case .choice(let index):
      return .text(choices[index])

    case .other:
      let text = otherField.stringValue

      return text.isEmpty ? .unanswered : .text(text)
    }
  }

  private func render() {
    if usesRadios {
      for (index, radio) in radios.enumerated() {
        radio.state = selection == .choice(index) ? .on : .off
      }

      otherRadio.state = selection == .other ? .on : .off
    } else {
      switch selection {
      case .none:
        popup.selectItem(at: 0)

      case .choice(let index):
        popup.selectItem(at: index + (hasPlaceholderItem ? 1 : 0))

      case .other:
        popup.selectItem(at: popup.numberOfItems - 1)
      }
    }

    otherField.isEnabled = selection == .other
    otherRow.isHidden = !allowsOther || (!usesRadios && selection != .other)
    clearButton.isHidden = question.isRequired || selection == .none
  }

  private func select(_ new: Selection) {
    selection = new

    render()
    onChange(answer)

    if usesRadios { onKeyViewsChange() }

    if new == .other { otherField.window?.makeFirstResponder(otherField) }
  }

  @objc private func picked(_ sender: NSButton) {
    select(.choice(sender.tag))
  }

  @objc private func pickedOther(_ sender: Any?) {
    select(.other)
  }

  @objc private func cleared(_ sender: Any?) {
    otherField.stringValue = ""

    select(.none)
  }

  @objc private func popupChanged(_ sender: Any?) {
    let index = popup.indexOfSelectedItem
    let offset = hasPlaceholderItem ? 1 : 0

    if hasPlaceholderItem && index == 0 {
      select(.none)
    } else if allowsOther && index == popup.numberOfItems - 1 {
      select(.other)
    } else {
      select(.choice(index - offset))
    }
  }

  func controlTextDidChange(_ notification: Notification) {
    let text = otherField.stringValue

    if text.utf8.count > FormLimits.maxOtherBytes {
      let cut = clipped(text, toBytes: FormLimits.maxOtherBytes)

      if let editor = notification.userInfo?["NSFieldEditor"] as? NSTextView { editor.string = cut }

      otherField.stringValue = cut
    }

    onChange(answer)
  }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    switch selector {
    case #selector(NSResponder.insertNewline(_:)):
      onReturn()
      return true

    case #selector(NSResponder.cancelOperation(_:)):
      onEscape()
      return true

    default:
      return false
    }
  }
}

// MARK: Several of several

/// A `multi`: one checkbox for each choice. A long list scrolls inside its own box. Once the
/// answer holds as many entries as the question takes, the boxes left unchecked stop taking input.
@MainActor
final class MultiField: FieldWidget {
  /// The most choices shown without a scroll box.
  static let inlineLimit = 8

  private let choices: [String]
  private var boxes: [NSButton] = []
  private let limit: Int

  override init(question: FormQuestion, styler: FormStyler) {
    guard case .multi(let choices, _) = question.type else {
      preconditionFailure("a multi field is built for a multi question")
    }

    self.choices = choices
    limit = question.answerEntryLimit

    super.init(question: question, styler: styler)

    var chosen: Set<String> = []

    if case .list(let entries) = FormSession.initialAnswer(question) { chosen = Set(entries) }

    let column = NSStackView()
    column.orientation = .vertical
    column.alignment = .leading
    column.spacing = 4

    for (index, choice) in choices.enumerated() {
      let box = NSButton(checkboxWithTitle: choice, target: self, action: #selector(toggled(_:)))
      box.tag = index
      box.state = chosen.contains(choice) ? .on : .off
      box.setAccessibilityIdentifier("question-\(question.id)-choice-\(index)")

      boxes.append(box)
      column.addArrangedSubview(box)
    }

    if choices.count > Self.inlineLimit {
      let scroll = NSScrollView()
      let document = FlippedView()

      column.translatesAutoresizingMaskIntoConstraints = false
      document.addSubview(column)

      NSLayoutConstraint.activate([
        column.topAnchor.constraint(equalTo: document.topAnchor, constant: 6),
        column.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 8),
        column.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -6),
        column.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor),
      ])

      scroll.documentView = document
      scroll.hasVerticalScroller = true
      scroll.borderType = .bezelBorder
      scroll.translatesAutoresizingMaskIntoConstraints = false
      scroll.heightAnchor.constraint(equalToConstant: 150).isActive = true
      document.translatesAutoresizingMaskIntoConstraints = false
      document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true

      root.addArrangedSubview(scroll)
      stretch(scroll)
    } else {
      root.addArrangedSubview(column)
    }

    refreshLimit()
  }

  override var focusTarget: NSView? { boxes.first }

  override var keyViews: [NSView] { boxes }

  override func lock() {
    for box in boxes { box.isEnabled = false }
  }

  private var selected: [String] {
    zip(choices, boxes).filter { $0.1.state == .on }.map(\.0)
  }

  private func refreshLimit() {
    let full = selected.count >= limit

    for box in boxes { box.isEnabled = box.state == .on || !full }
  }

  @objc private func toggled(_ sender: Any?) {
    refreshLimit()

    let entries = selected

    onChange(entries.isEmpty ? .unanswered : .list(entries))
  }
}
