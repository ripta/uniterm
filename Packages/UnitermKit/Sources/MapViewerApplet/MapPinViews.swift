import AppKit
import GeoData
import MapKit
import Theme

/// A set of pins that one source owns and replaces as a whole.
///
/// The file layer is its own case. A layer a command names is another case, so no command can name
/// a layer that collides with the file's.
enum MapLayer: Hashable {
  case file
  case command(String)

  /// The identifier MapKit clusters by. The file's has no prefix and a command's always has one,
  /// so a command named like the file's identifier still clusters apart from it.
  var clusteringIdentifier: String {
    switch self {
    case .file: return "file"
    case .command(let name): return "command:\(name)"
    }
  }
}

/// A pin on the map: the model pin, the layer it belongs to, and that layer's default accent.
final class MapPinAnnotation: NSObject, MKAnnotation {
  let pin: GeoPin
  let layer: MapLayer
  let layerAccent: ThemeToken

  /// Settable so MapKit can move a dragged file pin. The pin itself keeps the coordinate the file
  /// holds until the drag ends and the edit lands.
  @objc dynamic var coordinate: CLLocationCoordinate2D

  /// The label. MapKit shows it in the callout when the pin is selected.
  var title: String? { pin.label }

  /// True for a pin the user can change: one from the file, outside a geometry collection.
  let isEditable: Bool

  init(pin: GeoPin, layer: MapLayer, layerAccent: ThemeToken, isEditable: Bool = false) {
    self.pin = pin
    self.layer = layer
    self.layerAccent = layerAccent
    self.isEditable = isEditable
    coordinate = CLLocationCoordinate2D(
      latitude: pin.coordinate.latitude, longitude: pin.coordinate.longitude)
  }

  var accent: ThemeToken { pin.accent ?? layerAccent }
}

/// What a marker draws: a body in the accent, a neutral disc inside it, and a glyph or a count on
/// the disc.
///
/// The glyph color and the disc color come from the palette's flavor alone. Contrast between the
/// two therefore holds for every accent, and the render test samples it as drawn.
struct MarkerArt: Equatable {
  var body: ThemeColor
  var disc: ThemeColor
  var mark: ThemeColor
  var glyph: PinGlyph?
  var count: Int?

  static func of(palette: ThemePalette, accent: ThemeToken, glyph: PinGlyph?, count: Int? = nil)
    -> MarkerArt
  {
    MarkerArt(
      body: palette[accent], disc: palette.pinDisc, mark: palette.pinGlyph, glyph: glyph,
      count: count)
  }
}

/// Draws a `MarkerArt` in its bounds.
final class MarkerArtView: NSView {
  var art = MarkerArt(
    body: ThemePalette.latte[.blue], disc: ThemePalette.latte.pinDisc,
    mark: ThemePalette.latte.pinGlyph, glyph: nil, count: nil)
  { didSet { needsDisplay = true } }

  /// The disc's share of the marker's diameter.
  static let discRatio = 0.68

  override var isFlipped: Bool { false }

  override func draw(_ dirtyRect: NSRect) {
    let outer = bounds.insetBy(dx: 0.5, dy: 0.5)

    art.body.nsColor.setFill()
    NSBezierPath(ovalIn: outer).fill()

    let side = outer.width * Self.discRatio
    let disc = NSRect(
      x: outer.midX - side / 2, y: outer.midY - side / 2, width: side, height: side)

    art.disc.nsColor.setFill()
    NSBezierPath(ovalIn: disc).fill()

    drawMark(in: disc)
  }

  private func drawMark(in disc: NSRect) {
    let mark = art.mark.nsColor

    if let count = art.count {
      drawText(count > 99 ? "99+" : String(count), in: disc, color: mark, scale: 0.5)
      return
    }

    switch art.glyph {
    case .text(let text):
      drawText(text, in: disc, color: mark, scale: text.count > 1 ? 0.5 : 0.62)

    case .symbol(let name):
      if !drawSymbol(name, in: disc, color: mark) { drawDot(in: disc, color: mark) }

    case nil:
      drawDot(in: disc, color: mark)
    }
  }

  private func drawDot(in disc: NSRect, color: NSColor) {
    let side = disc.width * 0.3

    color.setFill()
    NSBezierPath(
      ovalIn: NSRect(
        x: disc.midX - side / 2, y: disc.midY - side / 2, width: side, height: side)
    ).fill()
  }

  private func drawText(_ text: String, in disc: NSRect, color: NSColor, scale: Double) {
    let font = NSFont.systemFont(ofSize: disc.height * scale, weight: .bold)
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let string = NSAttributedString(string: text, attributes: attributes)
    let size = string.size()

    string.draw(
      at: NSPoint(x: disc.midX - size.width / 2, y: disc.midY - size.height / 2))
  }

  /// Draws the symbol tinted `color`, or returns false when this macOS has no such symbol.
  private func drawSymbol(_ name: String, in disc: NSRect, color: NSColor) -> Bool {
    let configuration = NSImage.SymbolConfiguration(
      pointSize: disc.height * 0.5, weight: .bold)

    guard
      let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration)
    else { return false }

    let size = symbol.size
    let tinted = NSImage(size: size, flipped: false) { rect in
      symbol.draw(in: rect)
      color.set()
      rect.fill(using: .sourceAtop)

      return true
    }

    tinted.draw(
      in: NSRect(
        x: disc.midX - size.width / 2, y: disc.midY - size.height / 2, width: size.width,
        height: size.height))

    return true
  }
}

/// The view for a single pin or a cluster of a layer's pins. Both draw the same marker.
///
/// A new palette re-tints the marker in place, so a theme switch needs no reload of the pins.
final class MapMarkerView: MKAnnotationView {
  static let pinReuse = "map-pin"
  static let clusterReuse = "map-cluster"
  static let pinSide = 26.0
  static let clusterSide = 32.0

  private let art = MarkerArtView()
  private let editButton = NSButton(title: "Edit", target: nil, action: nil)

  /// Gets a press of the callout's Edit button.
  var onEdit: ((MapPinAnnotation) -> Void)?

  var palette = ThemePalette.latte {
    didSet { refresh() }
  }

  override var annotation: (any MKAnnotation)? {
    didSet { refresh() }
  }

  override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
    super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)

    let side = reuseIdentifier == Self.clusterReuse ? Self.clusterSide : Self.pinSide

    frame = NSRect(x: 0, y: 0, width: side, height: side)
    art.frame = bounds
    art.autoresizingMask = [.width, .height]
    addSubview(art)

    canShowCallout = reuseIdentifier == Self.pinReuse
    collisionMode = .circle

    editButton.bezelStyle = .inline
    editButton.controlSize = .small
    editButton.target = self
    editButton.action = #selector(edit)
    editButton.setAccessibilityIdentifier("map-pin-edit")

    refresh()
  }

  @objc private func edit() {
    guard let pin = annotation as? MapPinAnnotation else { return }

    onEdit?(pin)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  /// The art the marker draws now. A test reads it.
  var currentArt: MarkerArt { art.art }

  /// The inner art view, so a test can draw the marker as the user sees it.
  var artView: NSView { art }

  private func refresh() {
    if let pin = annotation as? MapPinAnnotation {
      clusteringIdentifier = pin.layer.clusteringIdentifier
      art.art = .of(palette: palette, accent: pin.accent, glyph: pin.pin.glyph)
      setAccessibilityLabel(pin.pin.label)
      isDraggable = pin.isEditable
      rightCalloutAccessoryView = pin.isEditable ? editButton : nil
    } else if let cluster = annotation as? MKClusterAnnotation {
      let members = cluster.memberAnnotations.compactMap { $0 as? MapPinAnnotation }
      let accent = members.first?.layerAccent ?? .blue

      art.art = .of(palette: palette, accent: accent, glyph: nil, count: members.count)
      setAccessibilityLabel("\(members.count) pins")
    }
  }
}
