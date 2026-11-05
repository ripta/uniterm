import AppKit
import GeoData
import MapKit
import Theme

/// The map viewer's body: a map view, and a banner over it that says why the map could not load.
///
/// The map belongs to MapKit, which owns pan and zoom. This view hands it a region and a style,
/// and reports the region the map settles on. It never reads its window's appearance. The owner
/// sets the light or dark look from the palette.
@MainActor
final class MapViewerView: NSView, MKMapViewDelegate {
  /// Gets the region the map settled on after the user moved it.
  var onRegionSettled: ((GeoRegion) -> Void)?

  /// Gets every region the map settles on, whoever moved it.
  var onRegionShown: ((GeoRegion) -> Void)?

  /// Gets the reason the map could not load.
  var onLoadFailure: ((String) -> Void)?

  /// Gets the files dropped on the pane. Returns false to refuse them.
  var onDrop: (([URL]) -> Bool)?

  let mapView = MKMapView()
  private let banner = NSBox()
  private let bannerLabel = NSTextField(wrappingLabelWithString: "")
  private let notices = NSBox()
  private let noticesLabel = NSTextField(wrappingLabelWithString: "")
  private var markers = NSHashTable<MapMarkerView>.weakObjects()
  private var palette = ThemePalette.latte
  private var pendingRegion: GeoRegion?
  private var eventMonitor: Any?

  /// True from the user's first gesture on the map until MapKit reports where it settled. Only a
  /// settle the user caused is reported. MapKit also reports a region after one is set, after a
  /// resize, and for its own default, and none of those belongs in the description.
  ///
  /// A gesture can move nothing, such as a click or a keystroke the map ignores. Setting a region
  /// and resizing the map both clear the mark, so a stale one never claims the report that follows.
  private(set) var userIsMoving = false
  private(set) var style = MapStyle.standard
  private(set) var failure: String?

  init() {
    super.init(frame: .zero)

    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityIdentifier("map-viewer")
    setAccessibilityLabel("Map")

    mapView.delegate = self
    mapView.translatesAutoresizingMaskIntoConstraints = false
    mapView.setAccessibilityIdentifier("map-viewer-map")
    addSubview(mapView)

    bannerLabel.translatesAutoresizingMaskIntoConstraints = false
    bannerLabel.setAccessibilityIdentifier("map-viewer-message")
    bannerLabel.maximumNumberOfLines = 0
    bannerLabel.alignment = .center

    banner.boxType = .custom
    banner.cornerRadius = 8
    banner.borderWidth = 0
    banner.contentViewMargins = NSSize(width: 12, height: 8)
    banner.translatesAutoresizingMaskIntoConstraints = false
    banner.contentView = bannerLabel
    banner.isHidden = true
    addSubview(banner)

    noticesLabel.translatesAutoresizingMaskIntoConstraints = false
    noticesLabel.setAccessibilityIdentifier("map-viewer-notices")
    noticesLabel.maximumNumberOfLines = 0

    notices.boxType = .custom
    notices.cornerRadius = 8
    notices.borderWidth = 0
    notices.contentViewMargins = NSSize(width: 12, height: 8)
    notices.translatesAutoresizingMaskIntoConstraints = false
    notices.contentView = noticesLabel
    notices.isHidden = true
    addSubview(notices)

    mapView.register(
      MapMarkerView.self, forAnnotationViewWithReuseIdentifier: MapMarkerView.pinReuse)
    mapView.register(
      MapMarkerView.self, forAnnotationViewWithReuseIdentifier: MapMarkerView.clusterReuse)
    registerForDraggedTypes([.fileURL])

    NSLayoutConstraint.activate([
      notices.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      notices.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -28),
      notices.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
      notices.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
      mapView.leadingAnchor.constraint(equalTo: leadingAnchor),
      mapView.trailingAnchor.constraint(equalTo: trailingAnchor),
      mapView.topAnchor.constraint(equalTo: topAnchor),
      mapView.bottomAnchor.constraint(equalTo: bottomAnchor),
      banner.centerXAnchor.constraint(equalTo: centerXAnchor),
      banner.topAnchor.constraint(equalTo: topAnchor, constant: 12),
      banner.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
      banner.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
      banner.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
    ])

    show(style: .standard)
    apply(.latte)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  // MARK: Region

  /// Shows `region`. A map with no size yet takes it at its first layout, since a region set on a
  /// map with no frame is fitted to nothing.
  func show(region: GeoRegion) {
    userIsMoving = false
    pendingRegion = region
    applyPendingRegion()
  }

  /// A resize makes MapKit report a region before the layout pass, so the mark clears here.
  override func setFrameSize(_ newSize: NSSize) {
    if newSize != frame.size { userIsMoving = false }

    super.setFrameSize(newSize)
  }

  override func layout() {
    super.layout()
    applyPendingRegion()
  }

  private func applyPendingRegion() {
    guard let region = pendingRegion, mapView.bounds.width > 0, mapView.bounds.height > 0 else {
      return
    }

    pendingRegion = nil

    mapView.setRegion(
      MKCoordinateRegion(
        center: CLLocationCoordinate2D(
          latitude: region.center.latitude, longitude: region.center.longitude),
        span: MKCoordinateSpan(
          latitudeDelta: region.span.latitudeDelta, longitudeDelta: region.span.longitudeDelta)),
      animated: false)
  }

  /// The region the map shows now, or nil when MapKit reports one a region cannot hold.
  var currentRegion: GeoRegion? {
    let region = mapView.region

    return GeoRegion(
      center: GeoCoordinate(
        latitude: region.center.latitude, longitude: region.center.longitude),
      span: GeoSpan(
        latitudeDelta: region.span.latitudeDelta, longitudeDelta: region.span.longitudeDelta))
  }

  func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
    if pendingRegion == nil, let shown = currentRegion { onRegionShown?(shown) }

    guard userIsMoving, pendingRegion == nil, let reported = currentRegion else { return }

    userIsMoving = false
    onRegionSettled?(reported)
  }

  // MARK: User gestures

  /// Marks the map as moved by the user. The next settle is reported, and the mark clears.
  func noteUserGesture() {
    userIsMoving = true
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()

    if let eventMonitor {
      NSEvent.removeMonitor(eventMonitor)
      self.eventMonitor = nil
    }

    guard window != nil else { return }

    let gestures: NSEvent.EventTypeMask = [
      .leftMouseDown, .leftMouseDragged, .leftMouseUp, .scrollWheel, .magnify, .smartMagnify,
      .keyDown,
    ]

    eventMonitor = NSEvent.addLocalMonitorForEvents(matching: gestures) { [weak self] event in
      MainActor.assumeIsolated { self?.observe(event) }

      return event
    }
  }

  func observe(_ event: NSEvent) {
    guard let window, event.window === window else { return }

    let point = mapView.convert(event.locationInWindow, from: nil)

    if event.type == .keyDown {
      // A command moves nothing on the map. Cmd-O and Cmd-K reach it while the map has focus.
      if event.modifierFlags.contains(.command) { return }

      if let responder = window.firstResponder as? NSView, responder.isDescendant(of: mapView) {
        noteUserGesture()
      }
    } else if mapView.isMousePoint(point, in: mapView.bounds) {
      noteUserGesture()

      if event.type == .leftMouseDown { takeFocus(in: window) }
    }
  }

  /// MapKit's map does not take the first responder on a click, so the pane's focus mark, which
  /// follows the responder, would stay on the pane clicked before.
  private func takeFocus(in window: NSWindow) {
    if let responder = window.firstResponder as? NSView, responder.isDescendant(of: mapView) {
      return
    }

    window.makeFirstResponder(mapView)
  }

  /// Stops watching events. The owner calls it when the pane closes.
  func stopObserving() {
    if let eventMonitor {
      NSEvent.removeMonitor(eventMonitor)
      self.eventMonitor = nil
    }
  }

  // MARK: Commands

  /// False in tests, so a command's move lands before the test reads the camera.
  var animatesCommands = true

  /// Moves the camera closer by `factor`, or away when it is below 1. MapKit clamps the distance
  /// to the zoom range it allows, so a zoom at either end does nothing.
  ///
  /// A zoom is the user's move. Its settle is reported, so the region it shows is saved.
  func zoom(closerBy factor: Double) {
    guard let camera = mapView.camera.copy() as? MKMapCamera else { return }

    camera.centerCoordinateDistance /= factor
    move(to: camera)
  }

  /// True when the map is turned away from north.
  var isTurned: Bool { abs(mapView.camera.heading) > 0.5 }

  /// Turns the map back to face north, keeping its center and zoom.
  func faceNorth() {
    guard let camera = mapView.camera.copy() as? MKMapCamera else { return }

    camera.heading = 0
    move(to: camera)
  }

  private func move(to camera: MKMapCamera) {
    noteUserGesture()
    mapView.setCamera(camera, animated: animatesCommands)
  }

  // MARK: Style

  func show(style: MapStyle) {
    self.style = style

    switch style {
    case .standard: mapView.preferredConfiguration = MKStandardMapConfiguration()
    case .satellite: mapView.preferredConfiguration = MKImageryMapConfiguration()
    case .hybrid: mapView.preferredConfiguration = MKHybridMapConfiguration()
    }
  }

  // MARK: Loading

  func mapViewDidFailLoadingMap(_ mapView: MKMapView, withError error: any Error) {
    let reason = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    let text =
      "The map could not load: \(reason). "
      + "The map needs a network connection to fetch its tiles."

    failure = text
    bannerLabel.stringValue = text
    banner.isHidden = false
    onLoadFailure?(text)
  }

  func mapViewDidFinishLoadingMap(_ mapView: MKMapView) {
    failure = nil
    banner.isHidden = true
  }

  // MARK: Pins

  /// Replaces every pin of `layer` with `pins`. The other layers keep theirs.
  func replacePins(layer: MapLayer, pins: [GeoPin], defaultAccent: ThemeToken) {
    removePins(layer: layer)

    mapView.addAnnotations(
      pins.map { MapPinAnnotation(pin: $0, layer: layer, layerAccent: defaultAccent) })
  }

  func removePins(layer: MapLayer) {
    let old = mapView.annotations.filter { ($0 as? MapPinAnnotation)?.layer == layer }

    mapView.removeAnnotations(old)
  }

  /// The pins of `layer` on the map now.
  func pins(layer: MapLayer) -> [GeoPin] {
    mapView.annotations.compactMap { $0 as? MapPinAnnotation }.filter { $0.layer == layer }
      .map(\.pin)
  }

  func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
    let reuse: String

    if annotation is MKClusterAnnotation {
      reuse = MapMarkerView.clusterReuse
    } else if annotation is MapPinAnnotation {
      reuse = MapMarkerView.pinReuse
    } else {
      return nil
    }

    let view = mapView.dequeueReusableAnnotationView(withIdentifier: reuse, for: annotation)

    if let marker = view as? MapMarkerView {
      marker.palette = palette
      markers.add(marker)
    }

    return view
  }

  // MARK: Notices

  /// Shows `lines` under the map, or hides the box when there are none.
  func show(notices lines: [String]) {
    noticesLabel.stringValue = lines.joined(separator: "\n")
    notices.isHidden = lines.isEmpty
  }

  /// The lines under the map now.
  var noticeLines: [String] {
    notices.isHidden ? [] : noticesLabel.stringValue.components(separatedBy: "\n")
  }

  // MARK: Drop

  private func droppedFiles(_ sender: any NSDraggingInfo) -> [URL] {
    let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]

    return sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options)
      as? [URL] ?? []
  }

  override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
    droppedFiles(sender).isEmpty ? [] : .copy
  }

  override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
    onDrop?(droppedFiles(sender)) ?? false
  }

  // MARK: Palette

  /// Sets the light or dark look from the palette's flavor. A standard or hybrid map follows it.
  /// A satellite map has no dark variant and does not change.
  func apply(_ palette: ThemePalette) {
    appearance = NSAppearance(named: palette.flavor.isDark ? .darkAqua : .aqua)

    self.palette = palette

    banner.fillColor = palette[.mantle].nsColor
    bannerLabel.textColor = palette[.text].nsColor
    notices.fillColor = palette[.mantle].nsColor
    noticesLabel.textColor = palette[.text].nsColor

    for marker in markers.allObjects { marker.palette = palette }
  }
}
