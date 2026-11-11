import AppKit
import AppletKit
import PaneModel
import Theme

/// What the pane's control badge shows. The window builds it from its own control table and the
/// pane tree, never from the applet.
struct PaneControlMark: Equatable {
  var access: PaneAccessMode
  var driver: PaneDriverKind

  /// What pane chrome calls the controller that owns a group the pane is a member of. Nil when no
  /// live controller owns one.
  var owner: String?

  /// The pane is a member of a group that no live controller owns now.
  var inUnownedGroup: Bool

  /// What pane chrome calls each controller with authority over the pane, the ones acting from it
  /// included. Revoke Controller ends all of them.
  var controllers: [String] = []

  /// The control the pane had when the layout was saved. It is inactive until the user enables it.
  var savedIntent: PaneAccessMode?

  var enableAvailable: Bool
  var revokeAvailable: Bool

  /// The badge shows only on a pane that is not in the default state.
  var isShown: Bool {
    access != .disconnected || driver != .none || owner != nil || inUnownedGroup
      || savedIntent != nil
  }

  /// The lines the badge's menu and tooltip show: the mode, the owner, and the driver.
  var summary: [String] {
    var lines: [String] = []

    switch access {
    case .remoteControlled: lines.append("Remote-controlled")
    case .disconnected: lines.append("Disconnected")
    }

    if let owner {
      lines.append("Owner: \(owner)")
    } else if inUnownedGroup {
      lines.append("Owner: none, the controller is gone")
    }

    for controller in controllers where controller != owner {
      lines.append("Controller: \(controller)")
    }

    lines.append(driver == .none ? "Driver: none" : "Driver: \(driver.rawValue)")

    if let savedIntent, access == .disconnected {
      lines.append("Saved as \(savedIntent.rawValue). Enable it again to resume.")
    }

    return lines
  }

  /// The value accessibility reads, and the UI tests with it.
  var accessibilityValue: String {
    [access.rawValue, owner.map { "owned by \($0)" }].compactMap { $0 }.joined(separator: ", ")
  }
}

/// The control actions the badge's menu offers. The window runs each one for this pane.
enum PaneControlAction {
  case enable
  case disconnect
  case revoke
}

/// Hosts one applet's view inside a pane. A gutter around the applet holds the focus marker.
@MainActor
final class PaneFrameView: NSView {
  static let gutter: CGFloat = 2

  /// The badge's side, in points.
  static let badgeSize: CGFloat = 20

  let paneID: NodeID
  private(set) var applet: any Applet

  private var palette: ThemePalette = .latte

  /// The host's own badge, above the applet's view. It opens the pane's control actions with the
  /// mouse, so they stay reachable when the applet takes every key.
  let controlBadge = NSButton()

  var controlMark: PaneControlMark? {
    didSet {
      if controlMark != oldValue { refreshBadge() }
    }
  }

  /// Runs a control action the user chose from the badge's menu.
  var onControlAction: ((PaneControlAction) -> Void)?

  /// Builds the badge's mark from the window's live state. The menu reads it as it opens, so it
  /// never shows a controller that has gone or misses one that has come.
  var currentControlMark: (() -> PaneControlMark?)?

  var isFocused = false {
    didSet { refresh() }
  }

  /// A lone pane has no neighbor to tell apart from, so it shows no marker.
  var showsFocusMarker = false {
    didSet { refresh() }
  }

  override var wantsUpdateLayer: Bool { true }

  override var isFlipped: Bool { true }

  override var mouseDownCanMoveWindow: Bool { false }

  init(paneID: NodeID, applet: any Applet) {
    self.paneID = paneID
    self.applet = applet
    super.init(frame: .zero)

    wantsLayer = true
    applet.view.frame = innerFrame
    addSubview(applet.view)

    controlBadge.isBordered = false
    controlBadge.bezelStyle = .regularSquare
    controlBadge.imagePosition = .imageOnly
    controlBadge.image = NSImage(
      systemSymbolName: "antenna.radiowaves.left.and.right",
      accessibilityDescription: "Pane control")
    controlBadge.wantsLayer = true
    controlBadge.layer?.cornerRadius = 4
    controlBadge.target = self
    controlBadge.action = #selector(showControlMenu(_:))
    controlBadge.setAccessibilityIdentifier("pane-control-\(paneID)")
    controlBadge.setAccessibilityLabel("Pane control")
    controlBadge.isHidden = true
    addSubview(controlBadge)

    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityIdentifier("pane-\(paneID)")
    refresh()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  /// Puts another applet in this pane. The old applet's view leaves, and the caller closes it.
  func replaceApplet(_ replacement: any Applet) {
    applet.view.removeFromSuperview()
    applet = replacement

    replacement.view.frame = innerFrame
    addSubview(replacement.view, positioned: .below, relativeTo: controlBadge)
    replacement.apply(palette)
  }

  private var innerFrame: NSRect {
    Self.appletFrame(in: bounds)
  }

  /// The applet's frame for a pane with these bounds: the bounds less the gutter on every side.
  /// It is the bounds inset by hand on purpose. Core Graphics returns the null rect, with an
  /// infinite origin, for bounds smaller than the inset, and a pane is zero size before its
  /// first layout.
  static func appletFrame(in bounds: NSRect) -> NSRect {
    NSRect(
      x: bounds.minX + gutter, y: bounds.minY + gutter,
      width: max(0, bounds.width - 2 * gutter), height: max(0, bounds.height - 2 * gutter))
  }

  override func resizeSubviews(withOldSize oldSize: NSSize) {
    applet.view.frame = innerFrame
    controlBadge.frame = Self.badgeFrame(in: bounds)
  }

  /// The badge sits in the pane's top right corner, inside the gutter.
  static func badgeFrame(in bounds: NSRect) -> NSRect {
    NSRect(
      x: max(0, bounds.maxX - gutter - badgeSize - 4), y: bounds.minY + gutter + 4,
      width: badgeSize, height: badgeSize)
  }

  private func refreshBadge() {
    guard let mark = controlMark, mark.isShown else {
      controlBadge.isHidden = true
      return
    }

    let active = mark.access == .remoteControlled || mark.driver != .none

    controlBadge.isHidden = false
    controlBadge.frame = Self.badgeFrame(in: bounds)
    controlBadge.toolTip = mark.summary.joined(separator: "\n")
    controlBadge.setAccessibilityValue(mark.accessibilityValue)
    controlBadge.contentTintColor = active ? palette[.peach].nsColor : palette[.overlay1].nsColor
    controlBadge.layer?.backgroundColor = palette[.surface0].cgColor
  }

  /// The menu names the mode, the owner, and the driver, then offers the actions that apply.
  func controlMenu() -> NSMenu {
    let menu = NSMenu()
    let mark = controlMark

    for line in mark?.summary ?? [] {
      let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
      item.isEnabled = false
      menu.addItem(item)
    }

    menu.addItem(.separator())

    let actions: [(String, PaneControlAction, Bool, String)] = [
      ("Enable Remote Control", .enable, mark?.enableAvailable == true, "enable"),
      ("Disconnect", .disconnect, mark?.access == .remoteControlled, "disconnect"),
      ("Revoke Controller", .revoke, mark?.revokeAvailable == true, "revoke"),
    ]

    menu.autoenablesItems = false

    for (title, action, enabled, name) in actions {
      let item = NSMenuItem(
        title: title, action: #selector(runControlAction(_:)), keyEquivalent: "")
      item.setAccessibilityIdentifier("pane-control-\(name)")
      item.target = self
      item.representedObject = action
      item.isEnabled = enabled
      menu.addItem(item)
    }

    return menu
  }

  @objc private func showControlMenu(_ sender: NSButton) {
    if let mark = currentControlMark?() { controlMark = mark }

    controlMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY), in: sender)
  }

  @objc private func runControlAction(_ item: NSMenuItem) {
    guard let action = item.representedObject as? PaneControlAction else { return }

    onControlAction?(action)
  }

  func apply(_ palette: ThemePalette) {
    self.palette = palette
    applet.apply(palette)
    refresh()
    refreshBadge()
  }

  private func refresh() {
    setAccessibilityValue(isFocused ? "focused" : "unfocused")
    needsDisplay = true
  }

  override func updateLayer() {
    guard let layer else { return }

    layer.backgroundColor = palette[.base].cgColor
    layer.borderWidth = isFocused && showsFocusMarker ? Self.gutter : 0
    layer.borderColor = palette[.blue].cgColor
  }
}
