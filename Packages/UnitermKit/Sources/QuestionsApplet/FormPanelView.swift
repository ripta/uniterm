import AppKit
import QuestionForm
import Theme

/// One tab's content: the requester's header, the form, and its buttons. After the form resolves,
/// the form gives way to what happened, and the header stays.
///
/// Return and Escape are unmodified keys inside this view. Return presses the primary button
/// outside a multiline field. Escape presses the cancel button. Neither reaches a window key.
@MainActor
final class FormPanelView: NSView {
  let session: FormSession
  let spec: FormSpec
  private(set) var requester: QuestionsRequester
  private let styler: FormStyler
  private let header: RequesterHeaderView
  private let scroll = NSScrollView()
  private let document = FlippedView()
  private let body = NSStackView()
  private let divider = NSBox()
  private let buttonBar = NSStackView()
  private var widgets: [String: FieldWidget] = [:]
  private var errorLabels: [String: NSTextField] = [:]
  private var buttons: [(button: FormButton, view: FormPushButton)] = []
  private var responderObservation: NSKeyValueObservation?
  private var fieldWithFocus: String?
  private(set) var isResolved = false

  /// The user pressed a button that finished the form.
  var onFinish: (FormOutcome) -> Void = { _ in }

  init(spec: FormSpec, requester: QuestionsRequester, palette: ThemePalette) {
    self.spec = spec
    self.requester = requester

    let styler = FormStyler(palette: palette)

    self.styler = styler
    session = FormSession(spec: spec)
    header = RequesterHeaderView(requester: requester, styler: styler)

    super.init(frame: .zero)

    build()

    session.onChange = { [weak self] in self?.refresh() }

    refresh()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override var acceptsFirstResponder: Bool { true }

  // MARK: Building

  private func build() {
    header.translatesAutoresizingMaskIntoConstraints = false
    scroll.translatesAutoresizingMaskIntoConstraints = false
    divider.translatesAutoresizingMaskIntoConstraints = false
    buttonBar.translatesAutoresizingMaskIntoConstraints = false

    divider.boxType = .separator

    body.orientation = .vertical
    body.alignment = .leading
    body.spacing = 18
    body.translatesAutoresizingMaskIntoConstraints = false

    document.translatesAutoresizingMaskIntoConstraints = false
    document.addSubview(body)

    scroll.documentView = document
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false
    scroll.automaticallyAdjustsContentInsets = false
    scroll.setAccessibilityIdentifier("questions-form")

    buttonBar.orientation = .horizontal
    buttonBar.alignment = .centerY
    buttonBar.spacing = 10
    buttonBar.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)
    buttonBar.setAccessibilityIdentifier("questions-buttons")

    addSubview(header)
    addSubview(scroll)
    addSubview(divider)
    addSubview(buttonBar)

    let clip = scroll.contentView
    let fill = body.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -20)

    fill.priority = NSLayoutConstraint.Priority(700)

    NSLayoutConstraint.activate([
      header.topAnchor.constraint(equalTo: topAnchor),
      header.leadingAnchor.constraint(equalTo: leadingAnchor),
      header.trailingAnchor.constraint(equalTo: trailingAnchor),
      scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
      scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
      divider.topAnchor.constraint(equalTo: scroll.bottomAnchor),
      divider.leadingAnchor.constraint(equalTo: leadingAnchor),
      divider.trailingAnchor.constraint(equalTo: trailingAnchor),
      buttonBar.topAnchor.constraint(equalTo: divider.bottomAnchor),
      buttonBar.leadingAnchor.constraint(equalTo: leadingAnchor),
      buttonBar.trailingAnchor.constraint(equalTo: trailingAnchor),
      buttonBar.bottomAnchor.constraint(equalTo: bottomAnchor),
      document.topAnchor.constraint(equalTo: clip.topAnchor),
      document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
      document.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
      body.topAnchor.constraint(equalTo: document.topAnchor, constant: 18),
      body.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 20),
      body.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor, constant: -20),
      body.widthAnchor.constraint(lessThanOrEqualToConstant: 680),
      body.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -20),
      fill,
    ])

    if let title = spec.title {
      let label = styler.wrappingLabel(title, style: .title2, bold: true)

      label.setAccessibilityIdentifier("questions-form-title")
      add(label)
    }

    let total = spec.questions.count
    var number = 0

    for (index, item) in spec.items.enumerated() {
      switch item {
      case .block(let block):
        add(FormBlocks.view(for: block, index: index, styler: styler))

      case .question(let question):
        number += 1
        add(questionBlock(question, number: number, of: total))
      }
    }

    buildButtons()

    styler.add { [weak self] palette in
      self?.layer?.backgroundColor = palette[.base].cgColor
    }

    wantsLayer = true
  }

  private func add(_ view: NSView) {
    view.translatesAutoresizingMaskIntoConstraints = false
    body.addArrangedSubview(view)
    view.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
  }

  private func questionBlock(_ question: FormQuestion, number: Int, of total: Int) -> NSView {
    let widget = FieldWidget.make(question, styler: styler)

    widget.onChange = { [weak self] answer in self?.session.set(answer, for: question.id) }
    widget.onReturn = { [weak self] in self?.pressPrimary() }
    widget.onEscape = { [weak self] in self?.pressCancel() }

    widgets[question.id] = widget

    let marker = question.isRequired ? "Required" : "Optional"
    let caption = styler.plainLabel(
      "Question \(number) of \(total) \u{00B7} \(marker)", style: .caption1, color: .subtext1)
    let text = styler.wrappingLabel(question.text, bold: true)
    let error = styler.wrappingLabel("", style: .callout, color: .red)

    caption.setAccessibilityIdentifier("question-\(question.id)-caption")
    text.setAccessibilityIdentifier("question-\(question.id)-text")
    error.setAccessibilityIdentifier("question-\(question.id)-error")
    error.isHidden = true
    errorLabels[question.id] = error

    let column = NSStackView(views: [caption, text])

    column.orientation = .vertical
    column.alignment = .leading
    column.spacing = 4

    if let detail = question.detail {
      let label = styler.wrappingLabel(detail, style: .callout, color: .subtext1)

      label.setAccessibilityIdentifier("question-\(question.id)-detail")
      column.addArrangedSubview(label)
      label.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
    }

    column.setCustomSpacing(8, after: column.arrangedSubviews.last ?? text)
    column.addArrangedSubview(widget.root)
    column.addArrangedSubview(error)

    text.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
    widget.root.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
    error.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true

    column.setAccessibilityElement(false)

    return column
  }

  private func buildButtons() {
    let spacer = NSView()

    spacer.translatesAutoresizingMaskIntoConstraints = false
    spacer.setContentHuggingPriority(.init(1), for: .horizontal)
    buttonBar.addArrangedSubview(spacer)

    for (index, definition) in spec.buttons.enumerated() {
      let view = FormPushButton(
        title: definition.label, target: self, action: #selector(pressed(_:)))

      view.tag = index
      view.bezelStyle = .rounded
      view.setAccessibilityIdentifier("form-button-\(definition.id)")
      view.onDisabledClick = { [weak self] in self?.attempt(definition) }

      switch definition.role {
      case .primary:
        styler.add { palette in
          view.bezelColor = palette[.blue].nsColor
          view.attributedTitle = NSAttributedString(
            string: definition.label,
            attributes: [.foregroundColor: palette.onAccent.nsColor, .font: view.font as Any])
        }

      case .destructive:
        view.hasDestructiveAction = true
        styler.add { palette in
          view.attributedTitle = NSAttributedString(
            string: definition.label,
            attributes: [.foregroundColor: palette[.red].nsColor, .font: view.font as Any])
        }

      case .normal, .cancel:
        break
      }

      buttons.append((definition, view))
      buttonBar.addArrangedSubview(view)
    }
  }

  // MARK: State

  /// Shows what the session now holds: each shown error, and each button's state.
  private func refresh() {
    guard !isResolved else { return }

    for question in spec.questions {
      guard let label = errorLabels[question.id] else { continue }

      let message = session.shownError(for: question.id)

      label.stringValue = message ?? ""
      label.isHidden = message == nil
      widgets[question.id]?.focusTarget?.setAccessibilityHelp(message)
    }

    for (definition, view) in buttons {
      let enabled = session.isEnabled(definition)

      view.isEnabled = enabled
      view.toolTip = enabled ? nil : "Answer every question and fix every error first."

      // A dimmed button takes no accessibility press, so it offers the try to submit as an action.
      view.setAccessibilityCustomActions(
        enabled
          ? []
          : [
            NSAccessibilityCustomAction(name: "Show what needs fixing") { [weak self] in
              MainActor.assumeIsolated {
                self?.attempt(definition)

                return true
              }
            }
          ])
    }
  }

  func updateRequester(_ requester: QuestionsRequester) {
    self.requester = requester

    header.update(requester)
  }

  func apply(_ palette: ThemePalette) {
    styler.apply(palette)

    appearance = NSAppearance(named: palette.flavor.isDark ? .darkAqua : .aqua)
  }

  // MARK: Pressing

  @objc private func pressed(_ sender: NSButton) {
    guard buttons.indices.contains(sender.tag) else { return }

    attempt(buttons[sender.tag].button)
  }

  /// Presses a button as a click or a key does. A form that does not pass shows every error and
  /// sends the keyboard to the first one.
  private func attempt(_ button: FormButton) {
    guard !isResolved else { return }

    switch session.press(button) {
    case .finished(let outcome):
      onFinish(outcome)

    case .blocked(let first):
      announceErrors()

      if let first { focus(question: first) }
    }
  }

  /// Says what a failed try to submit revealed, since the user may not see the errors appear.
  private func announceErrors() {
    let messages = spec.questions.compactMap { session.shownError(for: $0.id) }

    guard let first = messages.first else { return }

    let text =
      messages.count == 1 ? first : "\(messages.count) questions need attention. \(first)"

    NSAccessibility.post(
      element: self, notification: .announcementRequested,
      userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
  }

  func pressPrimary() {
    guard let primary = spec.buttons.first(where: { $0.role == .primary }) else { return }

    attempt(primary)
  }

  func pressCancel() {
    guard let cancel = spec.buttons.first(where: { $0.role == .cancel }) else { return }

    attempt(cancel)
  }

  override func keyDown(with event: NSEvent) {
    let modifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])

    guard !isResolved, modifiers.isEmpty else {
      super.keyDown(with: event)

      return
    }

    let isReturn = event.keyCode == 36 || event.keyCode == 76

    if isReturn && hasButton(.primary) {
      pressPrimary()
    } else if event.keyCode == 53 && hasButton(.cancel) {
      pressCancel()
    } else {
      super.keyDown(with: event)
    }
  }

  override func cancelOperation(_ sender: Any?) {
    guard hasButton(.cancel) else {
      super.cancelOperation(sender)

      return
    }

    pressCancel()
  }

  private func hasButton(_ role: FormButtonRole) -> Bool {
    spec.buttons.contains { $0.role == role }
  }

  // MARK: Focus

  /// Gives the keyboard to the first field, or to the panel when it has none. A control that takes
  /// the keyboard only under full keyboard access, such as a pop-up, may refuse it. The panel then
  /// keeps it, so Return and Escape still reach the form and no key falls to the pane behind.
  func focusFirst() {
    guard !isResolved else {
      window?.makeFirstResponder(self)

      return
    }

    let first = spec.questions.lazy.compactMap { self.widgets[$0.id]?.focusTarget }.first

    give(first)
  }

  func focus(question id: String) {
    guard let target = widgets[id]?.focusTarget else { return }

    give(target)
    target.scrollToVisible(target.bounds)
  }

  private func give(_ target: NSView?) {
    guard let window else { return }

    // A field that already has the keyboard keeps it. Asking again would end its editing, and
    // an empty required field would show its error before the user typed.
    if let target, Self.holdsKeyboard(target, in: window) { return }

    if let target, window.makeFirstResponder(target) { return }

    window.makeFirstResponder(self)
  }

  private static func holdsKeyboard(_ target: NSView, in window: NSWindow) -> Bool {
    if window.firstResponder === target { return true }

    guard let editor = window.firstResponder as? NSTextView else { return false }

    return editor.delegate === target
  }

  /// The view of the question's first control, for tests that look at what holds the keyboard.
  func focusTarget(for id: String) -> NSView? {
    widgets[id]?.focusTarget
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()

    responderObservation = nil

    guard let window else { return }

    responderObservation = window.observe(\.firstResponder, options: [.new]) {
      [weak self] window, _ in
      MainActor.assumeIsolated { self?.responderChanged(to: window.firstResponder) }
    }
  }

  /// The question whose field holds `responder`, or nil when the keyboard is elsewhere.
  func question(holding responder: NSResponder?) -> String? {
    var view = responder as? NSView

    if let editor = responder as? NSTextView, editor.isFieldEditor,
      let owner = editor.delegate as? NSView
    {
      view = owner
    }

    while let current = view {
      if let root = current as? FieldRootView, root.isDescendant(of: self) {
        return root.questionID
      }

      view = current.superview
    }

    return nil
  }

  private func responderChanged(to responder: NSResponder?) {
    let now = question(holding: responder)

    guard now != fieldWithFocus else { return }

    if let left = fieldWithFocus { session.leave(left) }

    fieldWithFocus = now
  }

  // MARK: Resolving

  /// Replaces the form with what happened. The panel keeps the keyboard, so focus stays in the tab.
  func showOutcome(_ outcome: FormOutcome) {
    guard !isResolved else { return }

    let hadFocus = (window?.firstResponder as? NSView)?.isDescendant(of: self) ?? false

    isResolved = true
    tearDown()

    for widget in widgets.values { widget.lock() }

    for view in body.arrangedSubviews.dropFirst(spec.title == nil ? 0 : 1) {
      body.removeArrangedSubview(view)
      view.removeFromSuperview()
    }

    let heading = styler.wrappingLabel(
      AnswerText.outcome(outcome, spec: spec, requester: requester.name), bold: true)

    heading.setAccessibilityIdentifier("questions-outcome")
    add(CalloutView(content: heading, tint: .green, bar: true, styler: styler))

    if case .submitted(_, _, let answers) = outcome {
      let rows: [[NSView]] = spec.questions.map { question in
        [
          styler.wrappingLabel(question.text, bold: true, color: .subtext1),
          styler.wrappingLabel(
            AnswerText.describe(answers[question.id] ?? .unanswered, for: question)),
        ]
      }

      if !rows.isEmpty {
        let grid = NSGridView(views: rows)

        grid.columnSpacing = 14
        grid.rowSpacing = 6
        grid.rowAlignment = .firstBaseline
        grid.setAccessibilityIdentifier("questions-answers")
        add(grid)
      }
    }

    buttonBar.removeFromSuperview()
    divider.removeFromSuperview()

    scroll.bottomAnchor.constraint(equalTo: bottomAnchor).isActive = true

    if hadFocus { window?.makeFirstResponder(self) }
  }

  /// Releases what lives outside the view tree.
  func tearDown() {
    responderObservation = nil

    for widget in widgets.values { widget.tearDown() }
  }
}
