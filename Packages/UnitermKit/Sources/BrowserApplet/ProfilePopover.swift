import AppKit
import Theme

/// The popover the profile button opens. It names the profile and says what the profile shares.
///
/// It has no controls. Creating and switching profiles are expected to land here later.
@MainActor
final class ProfilePopover {
  static let explanation = "Every browser pane shares this profile's logins and site data."

  private static let width: CGFloat = 260

  let nameLabel: NSTextField
  private let explanationLabel = NSTextField(wrappingLabelWithString: ProfilePopover.explanation)
  private let content = ProfilePopoverContent()
  private let popover = NSPopover()

  init(profileName: String) {
    nameLabel = NSTextField(labelWithString: profileName)

    nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
    nameLabel.lineBreakMode = .byTruncatingTail
    nameLabel.setAccessibilityIdentifier("browser-profile-name")

    explanationLabel.font = .systemFont(ofSize: 11)
    explanationLabel.setAccessibilityIdentifier("browser-profile-note")

    let stack = NSStackView(views: [nameLabel, explanationLabel])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 6
    stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
    stack.translatesAutoresizingMaskIntoConstraints = false

    content.wantsLayer = true
    content.addSubview(stack)

    NSLayoutConstraint.activate([
      content.widthAnchor.constraint(equalToConstant: Self.width),
      stack.topAnchor.constraint(equalTo: content.topAnchor),
      stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
    ])

    explanationLabel.preferredMaxLayoutWidth = Self.width - 28

    let controller = NSViewController()
    controller.view = content

    popover.contentViewController = controller
    popover.behavior = .transient

    content.onCancel = { [weak popover] in popover?.close() }

    apply(.latte)
  }

  /// Shows the popover below `anchor`, or closes it when it already shows.
  func toggle(relativeTo anchor: NSView) {
    if popover.isShown {
      popover.close()
      return
    }

    popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)

    content.window?.makeKey()
    content.window?.makeFirstResponder(content)
  }

  /// Themes the popover. It is safe while the popover shows, since the content and the popover's
  /// appearance both update in place.
  func apply(_ palette: ThemePalette) {
    popover.appearance = NSAppearance(named: palette.flavor.isDark ? .darkAqua : .aqua)
    content.appearance = popover.appearance
    content.layer?.backgroundColor = palette[.base].cgColor
    nameLabel.textColor = palette[.text].nsColor
    explanationLabel.textColor = palette[.subtext0].nsColor
  }
}

/// The popover's content. The popover holds no control, so without this view nothing in it can take
/// the keyboard, and Escape would go to the address bar and leave the popover open.
private final class ProfilePopoverContent: NSView {
  var onCancel: () -> Void = {}

  override var acceptsFirstResponder: Bool { true }

  override func cancelOperation(_ sender: Any?) {
    onCancel()
  }
}
