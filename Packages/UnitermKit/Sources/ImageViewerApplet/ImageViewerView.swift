import AppKit
import ImageViewerModel
import QuartzCore
import Theme

/// What the pane shows apart from the image: a message, and the buttons that go with it.
struct PaneMessage: Equatable {
  var text: String
  var offersOpen: Bool
  var offersRetry: Bool
}

/// The image viewer's body. A layer holds the bitmap and is sized to fit the pane. A message and
/// its buttons stand in for the image when there is none.
///
/// A drop is accepted anywhere in the pane, and the owner decides what to do with it.
@MainActor
final class ImageViewerView: NSView {
  var onOpen: (() -> Void)?
  var onRetry: (() -> Void)?

  /// Gets the dropped file URLs, which may be none. Returns false to refuse them.
  var onDrop: (([URL]) -> Bool)?

  /// The pane changed size or moved to a display with another scale.
  var onGeometryChange: (() -> Void)?

  private let imageLayer = CALayer()
  private let messageLabel = NSTextField(wrappingLabelWithString: "")
  private let openButton = NSButton(title: "Open\u{2026}", target: nil, action: nil)
  private let retryButton = NSButton(title: "Retry", target: nil, action: nil)
  private let buttons = NSStackView()
  private let messageStack = NSStackView()
  private var native: PixelSize?

  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)

    wantsLayer = true
    registerForDraggedTypes([.fileURL, .URL, .tiff, .png])

    imageLayer.magnificationFilter = .linear
    imageLayer.minificationFilter = .trilinear
    imageLayer.contentsGravity = .resize
    imageLayer.isHidden = true
    layer?.addSublayer(imageLayer)

    messageLabel.alignment = .center
    messageLabel.font = .systemFont(ofSize: 13)
    messageLabel.setAccessibilityIdentifier("image-viewer-message")

    openButton.target = self
    openButton.action = #selector(openPressed)
    openButton.bezelStyle = .rounded
    openButton.setAccessibilityIdentifier("image-viewer-open")

    retryButton.target = self
    retryButton.action = #selector(retryPressed)
    retryButton.bezelStyle = .rounded
    retryButton.setAccessibilityIdentifier("image-viewer-retry")

    buttons.orientation = .horizontal
    buttons.spacing = 8
    buttons.addArrangedSubview(retryButton)
    buttons.addArrangedSubview(openButton)

    messageStack.orientation = .vertical
    messageStack.alignment = .centerX
    messageStack.spacing = 12
    messageStack.translatesAutoresizingMaskIntoConstraints = false
    messageStack.addArrangedSubview(messageLabel)
    messageStack.addArrangedSubview(buttons)
    addSubview(messageStack)

    NSLayoutConstraint.activate([
      messageStack.centerXAnchor.constraint(equalTo: centerXAnchor),
      messageStack.centerYAnchor.constraint(equalTo: centerYAnchor),
      messageStack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
      messageStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
    ])

    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityIdentifier("image-viewer")
    apply(.latte)
    show(message: PaneMessage(text: "", offersOpen: false, offersRetry: false))
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  /// The scale of the display the pane is on.
  var backingScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

  /// The size `native` shows at fit in this pane, in backing pixels. Nothing is enlarged.
  func displayedPixels(for native: PixelSize) -> PixelSize {
    let points = FitMath.fitSize(
      image: native,
      in: PixelSize(
        width: Int(bounds.width.rounded(.down)), height: Int(bounds.height.rounded(.down))))

    let scale = Double(backingScale)

    return PixelSize(
      width: Int((Double(points.width) * scale).rounded()),
      height: Int((Double(points.height) * scale).rounded()))
  }

  func apply(_ palette: ThemePalette) {
    appearance = NSAppearance(named: palette.flavor == .mocha ? .darkAqua : .aqua)
    layer?.backgroundColor = palette[.base].cgColor
    messageLabel.textColor = palette[.subtext1].nsColor
  }

  /// Shows `image`, whose pixels are of `native` size at full resolution.
  func show(image: CGImage, native: PixelSize, hdr: Bool) {
    self.native = native

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    imageLayer.contents = image
    imageLayer.preferredDynamicRange = hdr ? .high : .standard
    imageLayer.isHidden = false
    CATransaction.commit()

    messageStack.isHidden = true
    needsLayout = true
    setAccessibilityLabel("Image")
  }

  /// Swaps the bitmap without touching the pane's state, as an animation does.
  func swap(image: CGImage) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    imageLayer.contents = image
    CATransaction.commit()
  }

  func show(message: PaneMessage) {
    native = nil
    imageLayer.contents = nil
    imageLayer.isHidden = true
    messageStack.isHidden = false
    messageLabel.stringValue = message.text
    messageLabel.isHidden = message.text.isEmpty
    openButton.isHidden = !message.offersOpen
    retryButton.isHidden = !message.offersRetry
    buttons.isHidden = !message.offersOpen && !message.offersRetry
    setAccessibilityLabel(message.text)
  }

  /// The frame of the image layer in points, or nil with no image.
  var imageFrame: CGRect? {
    guard !imageLayer.isHidden else { return nil }

    return imageLayer.frame
  }

  override func layout() {
    super.layout()

    CATransaction.begin()
    CATransaction.setDisableActions(true)

    if let native {
      let size = FitMath.fitSize(
        image: native,
        in: PixelSize(width: Int(bounds.width), height: Int(bounds.height)))

      imageLayer.contentsScale = backingScale
      imageLayer.frame = CGRect(
        x: ((bounds.width - CGFloat(size.width)) / 2).rounded(),
        y: ((bounds.height - CGFloat(size.height)) / 2).rounded(),
        width: CGFloat(size.width), height: CGFloat(size.height))
    }

    CATransaction.commit()

    onGeometryChange?()
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    onGeometryChange?()
  }

  @objc private func openPressed() {
    onOpen?()
  }

  @objc private func retryPressed() {
    onRetry?()
  }

  // MARK: Drop

  private func droppedFiles(_ sender: any NSDraggingInfo) -> [URL] {
    let objects = sender.draggingPasteboard.readObjects(
      forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])

    return (objects as? [URL]) ?? []
  }

  override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
    .copy
  }

  override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
    onDrop?(droppedFiles(sender)) ?? false
  }
}
