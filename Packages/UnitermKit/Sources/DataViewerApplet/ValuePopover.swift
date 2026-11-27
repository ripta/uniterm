import AppKit
import Theme

/// A cell that the user asked to read in full: its whole text, the column it sits in, and where the
/// cell is.
struct ValueRequest {
  let text: String
  let title: String
  let rect: NSRect
  let anchor: NSView
}

/// A cell's whole value in a popover over the cell, as selectable text that scrolls, with a button
/// that copies it.
///
/// The table cuts a long value to fit its column. This shows every byte the store holds for the
/// cell, which is up to the 1 MiB cell cap. Copy writes to the pasteboard the owner passes in, so a
/// test never touches the system clipboard.
@MainActor
final class ValuePopover: NSObject, NSPopoverDelegate {
  private static let size = NSSize(width: 480, height: 280)

  let text: String
  let textView = NSTextView()
  let copyButton = NSButton(title: "Copy", target: nil, action: nil)

  private let popover = NSPopover()
  private let pasteboard: NSPasteboard
  private let titleLabel: NSTextField
  private var closed = false

  init(_ request: ValueRequest, palette: ThemePalette, pasteboard: NSPasteboard) {
    text = request.text
    self.pasteboard = pasteboard
    titleLabel = NSTextField(labelWithString: request.title)

    super.init()

    let content = NSView(frame: NSRect(origin: .zero, size: Self.size))
    content.setAccessibilityIdentifier("data-viewer-value")

    titleLabel.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.translatesAutoresizingMaskIntoConstraints = false

    textView.string = request.text
    textView.isEditable = false
    textView.isSelectable = true
    textView.isRichText = false
    textView.font = DataCell.font
    textView.textContainerInset = NSSize(width: 4, height: 4)
    textView.isVerticallyResizable = true
    textView.autoresizingMask = [.width]
    textView.textContainer?.widthTracksTextView = true
    textView.setAccessibilityIdentifier("data-viewer-value-text")
    textView.setAccessibilityLabel("Value of \(request.title)")

    let scroll = NSScrollView()
    scroll.documentView = textView
    scroll.hasVerticalScroller = true
    scroll.borderType = .noBorder
    scroll.drawsBackground = false
    scroll.translatesAutoresizingMaskIntoConstraints = false

    copyButton.target = self
    copyButton.action = #selector(copyValue)
    copyButton.bezelStyle = .rounded
    copyButton.controlSize = .small
    copyButton.translatesAutoresizingMaskIntoConstraints = false
    copyButton.setAccessibilityIdentifier("data-viewer-value-copy")
    copyButton.setAccessibilityLabel("Copy the value")

    content.addSubview(titleLabel)
    content.addSubview(scroll)
    content.addSubview(copyButton)

    NSLayoutConstraint.activate([
      titleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
      titleLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
      titleLabel.trailingAnchor.constraint(
        lessThanOrEqualTo: copyButton.leadingAnchor, constant: -8),
      copyButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
      copyButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
      scroll.topAnchor.constraint(equalTo: copyButton.bottomAnchor, constant: 8),
      scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
      scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
      scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
    ])

    let controller = NSViewController()
    controller.view = content
    controller.preferredContentSize = Self.size

    popover.contentViewController = controller
    popover.behavior = .transient
    popover.delegate = self

    apply(palette)
  }

  func present(relativeTo rect: NSRect, of anchor: NSView) {
    popover.show(relativeTo: rect, of: anchor, preferredEdge: .maxY)
    popover.contentViewController?.view.window?.makeFirstResponder(textView)
  }

  func apply(_ palette: ThemePalette) {
    popover.appearance = NSAppearance(named: palette.flavor == .mocha ? .darkAqua : .aqua)
    textView.textColor = palette[.text].nsColor
    textView.backgroundColor = .clear
    titleLabel.textColor = palette[.subtext1].nsColor
  }

  func close() {
    guard !closed else { return }

    closed = true
    popover.close()
  }

  func popoverDidClose(_ notification: Notification) {
    closed = true
  }

  @objc func copyValue() {
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
    copyButton.title = "Copied"
  }
}
