import AppKit
import Theme

/// The band at the top of every form, drawn by uniterm. It names who asks, exactly as the host
/// established it. A script supplies nothing in it, and the form's own title sits below it.
///
/// It is a full-width band with a bar down its leading edge and a line that says who wrote the
/// rest. Pending Requests and the system's alert sheets look nothing like it.
@MainActor
final class RequesterHeaderView: NSView {
  private let label: NSTextField
  private let name: NSTextField
  private let pane: NSTextField
  private let note: NSTextField
  private let bar = NSView()
  private let icon = NSImageView()
  private var requester: QuestionsRequester

  init(requester: QuestionsRequester, styler: FormStyler) {
    self.requester = requester

    label = styler.plainLabel("Asked by", style: .caption1, bold: true, color: .subtext1)
    name = styler.wrappingLabel(requester.name, style: .title3, bold: true)
    pane = styler.wrappingLabel("", style: .callout, color: .subtext1)
    note = styler.plainLabel(
      "uniterm draws this band. The program wrote everything below it.", style: .caption1,
      color: .subtext1)

    super.init(frame: .zero)

    wantsLayer = true

    bar.wantsLayer = true
    bar.translatesAutoresizingMaskIntoConstraints = false

    icon.image = NSImage(
      systemSymbolName: "person.crop.circle.badge.questionmark", accessibilityDescription: nil)
    icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular)
    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.setAccessibilityElement(false)

    name.setAccessibilityIdentifier("questions-requester-name")
    pane.setAccessibilityIdentifier("questions-requester-pane")

    let column = NSStackView(views: [label, name, pane, note])

    column.orientation = .vertical
    column.alignment = .leading
    column.spacing = 2
    column.setCustomSpacing(6, after: pane)
    column.translatesAutoresizingMaskIntoConstraints = false

    addSubview(bar)
    addSubview(icon)
    addSubview(column)

    NSLayoutConstraint.activate([
      bar.leadingAnchor.constraint(equalTo: leadingAnchor),
      bar.topAnchor.constraint(equalTo: topAnchor),
      bar.bottomAnchor.constraint(equalTo: bottomAnchor),
      bar.widthAnchor.constraint(equalToConstant: 6),
      icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
      icon.topAnchor.constraint(equalTo: topAnchor, constant: 14),
      icon.widthAnchor.constraint(equalToConstant: 28),
      column.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
      column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
      column.topAnchor.constraint(equalTo: topAnchor, constant: 10),
      column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
      name.widthAnchor.constraint(equalTo: column.widthAnchor),
      pane.widthAnchor.constraint(equalTo: column.widthAnchor),
    ])

    styler.add { [weak self] palette in
      self?.layer?.backgroundColor = palette[.mantle].cgColor
      self?.bar.layer?.backgroundColor = palette[.mauve].cgColor
      self?.icon.contentTintColor = palette[.mauve].nsColor
    }

    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityIdentifier("questions-requester")

    refresh()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  func update(_ requester: QuestionsRequester) {
    self.requester = requester

    refresh()
  }

  private func refresh() {
    name.stringValue = requester.name

    let line = requester.paneLine

    pane.stringValue = line ?? ""
    pane.isHidden = line == nil

    setAccessibilityLabel("Asked by \(requester.name)")
    setAccessibilityValue(line ?? "")
  }
}
