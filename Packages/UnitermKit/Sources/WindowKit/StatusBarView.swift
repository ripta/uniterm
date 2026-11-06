import AppKit
import Theme

extension ThemePalette {
  func color(for tone: BarTone) -> NSColor {
    switch tone {
    case .normal: return self[.subtext1].nsColor
    case .emphasized: return self[.text].nsColor
    case .warning: return self[.yellow].nsColor
    case .error: return self[.red].nsColor
    }
  }
}

/// The status bar region. It lays out the window's segments in one row.
///
/// The bar knows nothing about where it docks. The window moves this one view between edges, so a
/// dock change cannot change what the bar shows. A click anywhere on the bar asks to toggle the
/// history.
@MainActor
final class StatusBarView: NSView {
  static let height: CGFloat = 22

  /// The least width the message area keeps, however many slots compete for the bar. It fits a
  /// few words, which truncate. Applet segments leave the bar before the message goes below it.
  static let minimumMessageWidth: CGFloat = 64

  /// The room between the bar's edge and its segments, on each side.
  private static let edgeInset: CGFloat = 10

  /// The gap after the message area and after the last icon-only slot.
  private static let wideGap: CGFloat = 12

  /// The gap between two icon-only slots.
  private static let narrowGap: CGFloat = 6

  /// Runs when the user clicks the bar.
  var onActivate: (() -> Void)?

  /// Runs when the user clicks the dismiss control.
  var onDismiss: (() -> Void)?

  private(set) var segments: [BarSegment] = []

  private let stack = NSStackView()
  private var segmentViews: [BarSegmentID: SegmentView] = [:]
  private var palette: ThemePalette = .latte

  override var wantsUpdateLayer: Bool { true }

  /// A click on the bar toggles the history. It must not drag the window.
  override var mouseDownCanMoveWindow: Bool { false }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)

    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.distribution = .fill
    stack.spacing = Self.wideGap
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)

    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.edgeInset),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.edgeInset),
      stack.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])

    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityIdentifier("status-bar")
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  /// Every click on the bar lands on the bar, so a label cannot swallow it.
  override func hitTest(_ point: NSPoint) -> NSView? {
    guard let superview else { return nil }

    return bounds.contains(convert(point, from: superview)) ? self : nil
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)

    if let dismiss = frame(of: .dismiss), dismiss.insetBy(dx: -4, dy: -4).contains(point) {
      onDismiss?()
    } else {
      onActivate?()
    }
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    fitApplets()
  }

  /// Where a segment sits in the bar, or nil when it is not showing.
  func frame(of id: BarSegmentID) -> NSRect? {
    guard let view = segmentViews[id], view.superview != nil, !view.isHidden else { return nil }

    return convert(view.bounds, from: view)
  }

  func apply(_ palette: ThemePalette) {
    self.palette = palette
    needsDisplay = true

    for view in segmentViews.values {
      view.apply(palette)
    }
  }

  func show(_ segments: [BarSegment]) {
    self.segments = segments

    let live = Set(segments.map(\.id))
    for id in segmentViews.keys where !live.contains(id) {
      segmentViews.removeValue(forKey: id)?.removeFromSuperview()
    }

    var ordered: [SegmentView] = []

    for segment in segments {
      let view = segmentViews[segment.id] ?? makeSegmentView(segment.id)
      view.show(segment)
      ordered.append(view)
    }

    stack.setViews(ordered, in: .leading)

    for (index, segment) in segments.enumerated() {
      guard let view = segmentViews[segment.id] else { continue }

      let next = index + 1 < segments.count ? segments[index + 1] : nil
      stack.setCustomSpacing(gap(after: segment, before: next), after: view)
    }

    fitApplets()
  }

  /// A slot that shows only an icon sits close to the next one. Text sits further apart.
  private func gap(after segment: BarSegment, before next: BarSegment?) -> CGFloat {
    guard let next, isCompact(segment), isCompact(next) else { return Self.wideGap }

    return Self.narrowGap
  }

  private func isCompact(_ segment: BarSegment) -> Bool {
    segment.id != .message && segment.text == nil
  }

  /// Hides the applet segments that do not fit. The message area keeps its least width and every
  /// window slot stays, so a narrow window loses applet segments first, from the last one back.
  /// Both an applet segment and a slot are measured by the width they need on their own.
  private func fitApplets() {
    let available = bounds.width - 2 * Self.edgeInset
    var used: CGFloat = 0
    var fits = true

    for (index, segment) in segments.enumerated() {
      guard let view = segmentViews[segment.id] else { continue }

      let next = index + 1 < segments.count ? segments[index + 1] : nil
      let width: CGFloat

      if segment.id == .message {
        width = Self.minimumMessageWidth
      } else {
        view.isHidden = false
        width = view.fittingSize.width
      }

      let gap = gap(after: segment, before: next)

      if case .applet = segment.id {
        let needed = used + width
        fits = fits && needed <= available
        view.isHidden = !fits

        if fits { used = needed + gap }
      } else {
        used += width + gap
      }
    }
  }

  override func updateLayer() {
    layer?.backgroundColor = palette[.mantle].cgColor
  }

  private func makeSegmentView(_ id: BarSegmentID) -> SegmentView {
    let view = SegmentView(id: id)
    view.apply(palette)
    segmentViews[id] = view
    return view
  }
}

/// One segment: an optional icon and an optional line of text.
@MainActor
private final class SegmentView: NSStackView {
  private let id: BarSegmentID
  private let icon = NSImageView()
  private let label = NSTextField(labelWithString: "")
  private var palette: ThemePalette = .latte
  private var segment: BarSegment?

  init(id: BarSegmentID) {
    self.id = id
    super.init(frame: .zero)

    orientation = .horizontal
    alignment = .centerY
    spacing = 4

    icon.imageScaling = .scaleProportionallyDown
    icon.setContentHuggingPriority(.required, for: .horizontal)
    icon.setContentCompressionResistancePriority(.required, for: .horizontal)

    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1

    addArrangedSubview(icon)
    addArrangedSubview(label)

    // The message area takes the room that the other segments leave. They keep their own width.
    let flexible = id == .message
    setContentHuggingPriority(flexible ? .defaultLow : .defaultHigh, for: .horizontal)
    setContentCompressionResistancePriority(
      flexible ? NSLayoutConstraint.Priority(10) : .defaultHigh, for: .horizontal)
    label.setContentCompressionResistancePriority(
      flexible ? NSLayoutConstraint.Priority(10) : .defaultHigh, for: .horizontal)
    label.setContentHuggingPriority(flexible ? .defaultLow : .defaultHigh, for: .horizontal)

    if flexible {
      widthAnchor.constraint(greaterThanOrEqualToConstant: StatusBarView.minimumMessageWidth)
        .isActive = true
    }
  }

  @available(*, unavailable)
  required init(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  func apply(_ palette: ThemePalette) {
    self.palette = palette

    if let segment {
      show(segment)
    }
  }

  func show(_ segment: BarSegment) {
    self.segment = segment
    toolTip = segment.toolTip

    let color = palette.color(for: segment.tone)
    let weight: NSFont.Weight = segment.tone == .emphasized ? .semibold : .regular

    label.font = .systemFont(ofSize: 11, weight: weight)
    label.textColor = color
    label.stringValue = segment.text ?? ""
    label.isHidden = segment.text == nil

    if let name = segment.symbolName,
      let image = NSImage(
        systemSymbolName: name, accessibilityDescription: segment.accessibilityLabel)
    {
      icon.image = image.withSymbolConfiguration(.init(pointSize: 11, weight: weight))
      icon.contentTintColor = color
      icon.isHidden = false
    } else {
      icon.image = nil
      icon.isHidden = true
    }

    // The text carries the identifier when there is any. An icon-only segment carries it itself.
    if segment.text != nil {
      label.setAccessibilityIdentifier(id.identifier)
      icon.setAccessibilityElement(false)
    } else {
      icon.setAccessibilityIdentifier(id.identifier)
      icon.setAccessibilityElement(true)
      icon.setAccessibilityLabel(segment.accessibilityLabel)
    }
  }
}
