import AppKit
import QuestionForm
import Theme

/// A tinted box around a view, with a bar down its leading edge.
@MainActor
final class CalloutView: NSView {
  init(content: NSView, tint: ThemeToken, bar: Bool, styler: FormStyler) {
    super.init(frame: .zero)

    wantsLayer = true
    layer?.cornerRadius = 6

    let barView = NSView()

    barView.wantsLayer = true
    barView.translatesAutoresizingMaskIntoConstraints = false
    barView.isHidden = !bar
    content.translatesAutoresizingMaskIntoConstraints = false

    addSubview(barView)
    addSubview(content)

    NSLayoutConstraint.activate([
      barView.leadingAnchor.constraint(equalTo: leadingAnchor),
      barView.topAnchor.constraint(equalTo: topAnchor),
      barView.bottomAnchor.constraint(equalTo: bottomAnchor),
      barView.widthAnchor.constraint(equalToConstant: 4),
      content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: bar ? 14 : 10),
      content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      content.topAnchor.constraint(equalTo: topAnchor, constant: 8),
      content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
    ])

    styler.add { [weak self] palette in
      self?.layer?.backgroundColor = palette[tint].nsColor.withAlphaComponent(0.14).cgColor
      barView.layer?.backgroundColor = palette[tint].cgColor
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }
}

/// Draws a content block. Every block is plain text. None holds a link, and none can run anything.
@MainActor
enum FormBlocks {
  static func view(for block: FormBlock, index: Int, styler: FormStyler) -> NSView {
    let view: NSView

    switch block {
    case .paragraph(let text):
      view = styler.wrappingLabel(text)

    case .list(let entries):
      view = list(entries, styler: styler)

    case .code(let text):
      view = code(text, styler: styler)

    case .table(let rows):
      view = table(rows, styler: styler)

    case .notice(let level, let text):
      view = notice(level: level, text: text, styler: styler)
    }

    view.setAccessibilityIdentifier("form-block-\(index)")

    if !(view is NSTextField) {
      view.setAccessibilityElement(true)
      view.setAccessibilityRole(.group)
    }

    return view
  }

  private static func list(_ entries: [String], styler: FormStyler) -> NSView {
    let column = NSStackView()

    column.orientation = .vertical
    column.alignment = .leading
    column.spacing = 4

    for entry in entries {
      let bullet = styler.plainLabel("\u{2022}", color: .subtext1)
      let text = styler.wrappingLabel(entry)
      let row = NSStackView(views: [bullet, text])

      row.orientation = .horizontal
      row.alignment = .firstBaseline
      row.spacing = 8

      column.addArrangedSubview(row)
    }

    return column
  }

  private static func code(_ text: String, styler: FormStyler) -> NSView {
    let label = styler.wrappingLabel(text)

    label.font = NSFont.monospacedSystemFont(
      ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize - 1, weight: .regular)

    return CalloutView(content: label, tint: .overlay1, bar: false, styler: styler)
  }

  private static func table(_ rows: [FormTableRow], styler: FormStyler) -> NSView {
    let cells: [[NSView]] = rows.map { row in
      [
        styler.wrappingLabel(row.key, bold: true, color: .subtext1),
        styler.wrappingLabel(row.value),
      ]
    }

    let grid = NSGridView(views: cells)

    grid.columnSpacing = 14
    grid.rowSpacing = 6
    grid.rowAlignment = .firstBaseline

    if grid.numberOfColumns > 0 { grid.column(at: 0).xPlacement = .leading }

    return grid
  }

  private static func notice(level: FormNoticeLevel, text: String, styler: FormStyler) -> NSView {
    let name: String
    let symbol: String
    let tint: ThemeToken

    switch level {
    case .info:
      (name, symbol, tint) = ("Note", "info.circle.fill", .blue)

    case .warning:
      (name, symbol, tint) = ("Warning", "exclamationmark.triangle.fill", .yellow)

    case .danger:
      (name, symbol, tint) = ("Danger", "xmark.octagon.fill", .red)
    }

    let icon = NSImageView(
      image: NSImage(systemSymbolName: symbol, accessibilityDescription: name) ?? NSImage())
    let heading = styler.plainLabel(name, bold: true)
    let body = styler.wrappingLabel(text)
    let top = NSStackView(views: [icon, heading])

    top.orientation = .horizontal
    top.spacing = 6
    top.alignment = .centerY

    let column = NSStackView(views: [top, body])

    column.orientation = .vertical
    column.alignment = .leading
    column.spacing = 4
    body.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true

    styler.add { palette in icon.contentTintColor = palette[tint].nsColor }

    return CalloutView(content: column, tint: tint, bar: true, styler: styler)
  }
}
