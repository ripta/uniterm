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

/// A key the image view acts on.
enum ImageKey: Equatable {
  case left
  case right
  case up
  case down
  case home
  case end
  case space
  case shiftSpace

  /// The key an event stands for, or nil when the view leaves it alone. A command, option, or
  /// control chord is never an image key, so the menu and the palette's own text keys are not
  /// taken from them.
  static func key(for event: NSEvent) -> ImageKey? {
    guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else {
      return nil
    }

    switch event.specialKey {
    case .leftArrow: return .left
    case .rightArrow: return .right
    case .upArrow: return .up
    case .downArrow: return .down
    case .home: return .home
    case .end: return .end
    default: break
    }

    guard event.charactersIgnoringModifiers == " " else { return nil }

    return event.modifierFlags.contains(.shift) ? .shiftSpace : .space
  }
}

/// One decoded tile of the zoomed image, ready to draw.
struct TileSprite {
  var key: TileKey
  var image: CGImage

  /// The tile's rectangle in its level's pixels.
  var rect: (x: Int, y: Int, width: Int, height: Int)

  /// Level pixels per native pixel.
  var ratio: Double

  var hdr: Bool
}

/// What changed in the viewport, for the owner that keeps tiles for it.
enum ViewportChange {
  /// The user moved the image or changed the zoom in one step.
  case moved

  /// A pinch ended. The view scaled what it held until now.
  case settled

  /// The pane changed size or moved to a display with another scale.
  case resized
}

/// The image viewer's body. A layer holds the fit-size bitmap, the backdrop, and sits where the
/// zoom puts the image. Tile layers lie over it and show the detail the helper decoded. A message
/// and its buttons stand in for the image when there is none.
///
/// The view owns the zoom and the pan. It never waits for a tile: a missing tile shows the
/// backdrop scaled to the same place.
///
/// A drop is accepted anywhere in the pane, and the owner decides what to do with it.
@MainActor
final class ImageViewerView: NSView {
  var onOpen: (() -> Void)?
  var onRetry: (() -> Void)?

  /// Gets a key the view acts on. Returns false to leave it unhandled.
  var onKey: ((ImageKey) -> Bool)?

  /// Gets the dropped file URLs, which may be none. Returns false to refuse them.
  var onDrop: (([URL]) -> Bool)?

  /// The pane changed size or moved to a display with another scale.
  var onGeometryChange: (() -> Void)?

  /// The zoom or the pan changed. Not called while a pinch is in progress.
  var onViewportChange: ((ViewportChange) -> Void)?

  private let imageLayer = CALayer()
  private let tileContainer = CALayer()
  private var tileLayers: [TileKey: CALayer] = [:]
  private var sprites: [TileKey: TileSprite] = [:]
  private let messageLabel = NSTextField(wrappingLabelWithString: "")
  private let openButton = NSButton(title: "Open\u{2026}", target: nil, action: nil)
  private let retryButton = NSButton(title: "Retry", target: nil, action: nil)
  private let buttons = NSStackView()
  private let messageStack = NSStackView()
  /// The zoom and pan of the image on screen, or nil while there is none.
  private(set) var viewport: ZoomViewport?

  /// True from the first to the last event of a pinch.
  private(set) var isPinching = false

  /// A pinch began. The viewport is reported only when the fingers lift, so this is the owner's
  /// first word of the gesture.
  var onPinchBegin: (() -> Void)?

  private var resignObserver: (any NSObjectProtocol)?

  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)

    wantsLayer = true
    registerForDraggedTypes([.fileURL, .URL, .tiff, .png])

    layer?.masksToBounds = true

    imageLayer.magnificationFilter = .linear
    imageLayer.minificationFilter = .trilinear
    imageLayer.contentsGravity = .resize
    imageLayer.isHidden = true
    layer?.addSublayer(imageLayer)

    tileContainer.masksToBounds = true
    layer?.addSublayer(tileContainer)

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
  var backingScale: CGFloat {
    backingScaleSource?() ?? window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
  }

  /// Stands in for the window's display, so a test can move the pane to a display of another
  /// scale.
  var backingScaleSource: (() -> CGFloat)?

  /// The size `native` shows at fit in this pane, in backing pixels. Nothing is enlarged past
  /// actual size.
  func displayedPixels(for native: PixelSize, actualScale: Double) -> PixelSize {
    let fit = ZoomViewport(native: native, pane: bounds.size, actualScale: actualScale).fitScale
    let scale = Double(backingScale)

    return PixelSize(
      width: Int((Double(native.width) * fit * scale).rounded()),
      height: Int((Double(native.height) * fit * scale).rounded()))
  }

  func apply(_ palette: ThemePalette) {
    appearance = NSAppearance(named: palette.flavor == .mocha ? .darkAqua : .aqua)
    layer?.backgroundColor = palette[.base].cgColor
    messageLabel.textColor = palette[.subtext1].nsColor
  }

  /// Shows `image`, whose pixels are of `native` size at full resolution. The image shows at fit,
  /// unless `keepingZoom` is set and the image on screen is the same size, as when a sharper decode
  /// of the same image replaces its backdrop.
  func show(
    image: CGImage, native: PixelSize, actualScale: Double, hdr: Bool, keepingZoom: Bool = false
  ) {
    let keep = keepingZoom && viewport?.native == native

    if !keep { isPinching = false }

    if !keep {
      viewport = ZoomViewport(native: native, pane: bounds.size, actualScale: actualScale)
      setTiles([])
    }

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    imageLayer.contents = image
    imageLayer.magnificationFilter = .linear
    imageLayer.preferredDynamicRange = hdr ? .high : .standard
    imageLayer.isHidden = false
    CATransaction.commit()

    messageStack.isHidden = true
    needsLayout = true
    placeLayers()
    setAccessibilityLabel("Image")
  }

  /// Swaps the bitmap without touching the pane's state, as an animation does. A frame decoded for
  /// a zoom magnifies with nearest-neighbor sampling, as the tiles of a still do.
  func swap(image: CGImage, zoomed: Bool = false) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    imageLayer.contents = image
    imageLayer.magnificationFilter = zoomed ? .nearest : .linear
    CATransaction.commit()
  }

  func show(message: PaneMessage) {
    isPinching = false
    viewport = nil
    setTiles([])
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

  override func keyDown(with event: NSEvent) {
    if let key = ImageKey.key(for: event), onKey?(key) == true { return }

    super.keyDown(with: event)
  }

  override func layout() {
    super.layout()

    viewport?.resize(pane: bounds.size)
    placeLayers()
    onGeometryChange?()
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    placeLayers()
    onGeometryChange?()
  }

  /// Puts the backdrop and every tile where the viewport says. Edges snap to whole device pixels,
  /// so neighboring tiles share an edge and no seam shows.
  private func placeLayers() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }

    tileContainer.frame = bounds
    tileContainer.isGeometryFlipped = !(layer?.isGeometryFlipped ?? false)

    guard let viewport else { return }

    let backing = backingScale
    let origin = viewport.origin
    let scale = viewport.scale

    func snap(_ value: Double) -> CGFloat {
      CGFloat((value * Double(backing)).rounded() / Double(backing))
    }

    imageLayer.contentsScale = backing
    imageLayer.frame = CGRect(
      x: snap(origin.x), y: snap(origin.y),
      width: snap(Double(viewport.native.width) * scale),
      height: snap(Double(viewport.native.height) * scale))

    for (key, sprite) in sprites {
      guard let tile = tileLayers[key] else { continue }

      let left = snap(origin.x + Double(sprite.rect.x) / sprite.ratio * scale)
      let top = snap(origin.y + Double(sprite.rect.y) / sprite.ratio * scale)
      let right = snap(origin.x + Double(sprite.rect.x + sprite.rect.width) / sprite.ratio * scale)
      let bottom = snap(
        origin.y + Double(sprite.rect.y + sprite.rect.height) / sprite.ratio * scale)

      tile.frame = CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }
  }

  /// Replaces the tiles on screen. A tile already shown keeps its layer.
  func setTiles(_ next: [TileSprite]) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }

    let wanted = Set(next.map(\.key))

    for key in tileLayers.keys where !wanted.contains(key) {
      tileLayers.removeValue(forKey: key)?.removeFromSuperlayer()
    }

    sprites = [:]

    for sprite in next {
      sprites[sprite.key] = sprite

      let tile: CALayer

      if let existing = tileLayers[sprite.key] {
        tile = existing
      } else {
        tile = CALayer()
        tile.magnificationFilter = .nearest
        tile.minificationFilter = .trilinear
        tile.contentsGravity = .resize
        tileContainer.addSublayer(tile)
        tileLayers[sprite.key] = tile
      }

      tile.contents = sprite.image
      tile.contentsScale = backingScale
      tile.preferredDynamicRange = sprite.hdr ? .high : .standard
    }

    placeLayers()
  }

  /// The number of tile layers on screen, for tests.
  var tileCount: Int { tileLayers.count }

  // MARK: Zoom

  enum ZoomTarget {
    case fit
    case actual
    case step(zoomingIn: Bool)
  }

  /// Changes the zoom. Returns false when nothing changed, as at fit when zooming out.
  @discardableResult
  func zoom(_ target: ZoomTarget, anchor: CGPoint? = nil) -> Bool {
    guard var next = viewport else { return false }

    let before = next

    switch target {
    case .fit: next.showFit()
    case .actual: next.showActualSize(backing: Double(backingScale))
    case .step(let zoomingIn):
      next.setScale(
        next.steppedScale(zoomingIn: zoomingIn), anchor: anchor, backing: Double(backingScale))
    }

    guard next != before else { return false }

    viewport = next
    placeLayers()
    onViewportChange?(.moved)

    return true
  }

  /// Puts back a viewport the pane held before, as when a zoom is refused.
  func restore(_ saved: ZoomViewport) {
    guard saved.native == viewport?.native else { return }

    var next = saved

    next.resize(pane: bounds.size)
    viewport = next
    placeLayers()
    onViewportChange?(.moved)
  }

  /// Moves the image under the pane by `delta` points. Does nothing at fit.
  @discardableResult
  func pan(byPoints delta: CGSize) -> Bool {
    guard var next = viewport, !next.isFit else { return false }

    let before = next

    next.pan(byPoints: delta)

    guard next != before else { return true }

    viewport = next
    placeLayers()

    if !isPinching { onViewportChange?(.moved) }

    return true
  }

  override func scrollWheel(with event: NSEvent) {
    guard viewport?.isFit == false else {
      super.scrollWheel(with: event)
      return
    }

    let unit: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10

    pan(byPoints: CGSize(width: event.scrollingDeltaX * unit, height: event.scrollingDeltaY * unit))
  }

  enum PinchPhase {
    case began
    case changed
    case ended
  }

  override func magnify(with event: NSEvent) {
    let phase: PinchPhase

    switch event.phase {
    case .began: phase = .began
    case .ended, .cancelled: phase = .ended
    default: phase = .changed
    }

    pinch(phase, magnification: event.magnification, at: convert(event.locationInWindow, from: nil))
  }

  /// Ends a pinch whose last event never came, as when the window loses key in the middle of one.
  /// AppKit promises an end event only while the gesture's window stays the target, so the view
  /// does not wait for one. The owner hears a settled viewport, as it would at a normal end.
  func cancelPinch() {
    guard isPinching else { return }

    isPinching = false
    onViewportChange?(.settled)
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()

    cancelPinch()

    if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }

    resignObserver = window.map { window in
      NotificationCenter.default.addObserver(
        forName: NSWindow.didResignKeyNotification, object: window, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.cancelPinch() }
      }
    }
  }

  isolated deinit {
    if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
  }

  /// One step of a pinch. The view scales what it holds while the fingers move. It reports a
  /// settled viewport once, when they lift, so the tiles for the new zoom are asked for then.
  func pinch(_ phase: PinchPhase, magnification: CGFloat, at location: CGPoint) {
    switch phase {
    case .began:
      isPinching = true
      onPinchBegin?()

    case .ended:
      isPinching = false
      onViewportChange?(.settled)
      return

    case .changed:
      break
    }

    guard var next = viewport else { return }

    next.zoom(by: 1 + Double(magnification), anchor: location, backing: Double(backingScale))

    guard next != viewport else { return }

    viewport = next
    placeLayers()
  }

  override func smartMagnify(with event: NSEvent) {
    if viewport?.isFit == true {
      zoom(.actual, anchor: convert(event.locationInWindow, from: nil))
    } else {
      zoom(.fit)
    }
  }

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
  }

  override func mouseDragged(with event: NSEvent) {
    pan(byPoints: CGSize(width: event.deltaX, height: event.deltaY))
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
