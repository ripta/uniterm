import AppKit
import GeoData
import MapKit
import PlaceSearch
import Theme

/// The map viewer's body: a map view, and a box over it that says the file failed or is opening.
///
/// The map belongs to MapKit, which owns pan and zoom. This view hands it a region and a style,
/// and reports the region the map settles on. It never reads its window's appearance. The owner
/// sets the light or dark look from the palette.
@MainActor
final class MapViewerView: NSView, MKMapViewDelegate, NSPopoverDelegate {
  /// Gets the region the map settled on after the user moved it.
  var onRegionSettled: ((GeoRegion) -> Void)?

  /// Gets every region the map settles on, whoever moved it.
  var onRegionShown: ((GeoRegion) -> Void)?

  /// Gets the region of a place the user picked in the place search.
  var onPlacePicked: ((GeoRegion) -> Void)?

  /// Gets a request to add a pin at a coordinate, from the map's context menu.
  var onAddPin: ((GeoCoordinate) -> Void)?

  /// Gets a pin the user edited in the popover: the pin as it was, and as it is now.
  var onUpdatePin: ((GeoPin, GeoPin) -> Void)?

  /// Gets a pin the user asked to remove.
  var onRemovePin: ((GeoPin) -> Void)?

  /// Gets the Add Pin button of the pin list.
  var onAddPinAtCenter: (() -> Void)?

  /// The applet's undo stack. The window's Undo reaches it through the responder chain while the
  /// map has focus.
  weak var ownUndoManager: UndoManager?

  override var undoManager: UndoManager? { ownUndoManager ?? super.undoManager }

  /// The file's pins in file order, as the last update gave them. MapKit keeps its annotations in no
  /// order, so the list reads this.
  private var filePinsInOrder: [GeoPin] = []

  /// The list of pins beside the map, while it shows.
  private(set) var pinList: PinListView?
  private var mapTrailing: NSLayoutConstraint?

  /// The pin editor, while it shows.
  private(set) var editor: (popover: NSPopover, controller: PinEditorController)?

  /// The place search over the map, while it shows.
  private(set) var placeSearch: PlaceSearchView?

  /// Gets the reason the map could not load.
  /// Called with why the map's tiles fail to load, and with nil once they load. MapKit can
  /// report the same failure many times.
  var onTilesChanged: ((String?) -> Void)?

  /// Gets the files dropped on the pane. Returns false to refuse them.
  var onDrop: (([URL]) -> Bool)?

  let mapView = MKMapView()
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
      mapView.topAnchor.constraint(equalTo: topAnchor),
      mapView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    let trailing = mapView.trailingAnchor.constraint(equalTo: trailingAnchor)
    trailing.isActive = true
    mapTrailing = trailing

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
      .keyDown, .rightMouseDown,
    ]

    eventMonitor = NSEvent.addLocalMonitorForEvents(matching: gestures) { [weak self] event in
      let taken = MainActor.assumeIsolated { () -> Bool in
        guard let self else { return false }

        if event.type == .rightMouseDown { return self.showContextMenu(for: event) }

        self.observe(event)
        return false
      }

      return taken ? nil : event
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
    } else if let placeSearch,
      placeSearch.isMousePoint(
        placeSearch.convert(event.locationInWindow, from: nil), in: placeSearch.bounds)
    {
      return
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

  // MARK: Editing pins

  /// The file pin at a point in the window, as a right-click finds it.
  private func filePin(atWindowPoint point: NSPoint) -> MapPinAnnotation? {
    var view = window?.contentView?.hitTest(point)

    while let current = view {
      if let marker = current as? MapMarkerView {
        return (marker.annotation as? MapPinAnnotation).flatMap { $0.isEditable ? $0 : nil }
      }

      view = current.superview
    }

    return nil
  }

  /// True while the map itself has the keyboard. Remove Pin's key is Cmd-Delete, which a text
  /// field such as the place search uses to delete text, so the key works only here.
  var mapHasKeyboard: Bool {
    guard let responder = window?.firstResponder as? NSView else { return false }

    return responder === mapView || responder.isDescendant(of: mapView)
  }

  /// The selected file pin, which Edit Pin and Remove Pin act on.
  var selectedFilePin: MapPinAnnotation? {
    mapView.selectedAnnotations.lazy.compactMap { $0 as? MapPinAnnotation }.first {
      $0.isEditable
    }
  }

  /// Shows the map's context menu for a right-click on the map, and returns true when it took the
  /// click. The map's own views never see it, since MapKit's inner views do not ask the map for a
  /// menu. A click on the place search or the pin list is theirs.
  private func showContextMenu(for event: NSEvent) -> Bool {
    guard let window, event.window === window else { return false }

    let point = mapView.convert(event.locationInWindow, from: nil)

    guard mapView.isMousePoint(point, in: mapView.bounds) else { return false }

    if let placeSearch,
      placeSearch.isMousePoint(
        placeSearch.convert(event.locationInWindow, from: nil), in: placeSearch.bounds)
    {
      return false
    }

    let menu = NSMenu()
    menu.setAccessibilityIdentifier("map-context-menu")
    contextItems(atWindowPoint: event.locationInWindow).forEach(menu.addItem)
    NSMenu.popUpContextMenu(menu, with: event, for: mapView)

    return true
  }

  /// The context menu's items for a click at a point in the window. A test reads them.
  func contextItems(atWindowPoint point: NSPoint) -> [NSMenuItem] {
    if let pin = filePin(atWindowPoint: point) {
      return [
        ClosureMenuItem("Edit Pin\u{2026}") { [weak self] in self?.showEditor(for: pin) },
        ClosureMenuItem("Remove Pin") { [weak self] in self?.onRemovePin?(pin.pin) },
      ]
    }

    let local = mapView.convert(point, from: nil)
    let coordinate = mapView.convert(local, toCoordinateFrom: mapView)
    let target = GeoCoordinate(latitude: coordinate.latitude, longitude: coordinate.longitude)

    return [ClosureMenuItem("Add Pin Here") { [weak self] in self?.onAddPin?(target) }]
  }

  /// A drag of a file pin ends as a move. MapKit moved the annotation, and the edit puts the file's
  /// new coordinate in place.
  func mapView(
    _ mapView: MKMapView, annotationView view: MKAnnotationView,
    didChange newState: MKAnnotationView.DragState,
    fromOldState oldState: MKAnnotationView.DragState
  ) {
    guard newState == .ending || newState == .canceling,
      let annotation = view.annotation as? MapPinAnnotation
    else { return }

    view.dragState = .none

    guard newState == .ending else { return }

    let moved = annotation.coordinate
    let old = annotation.pin
    let new = GeoPin(
      id: old.id, coordinate: GeoCoordinate(latitude: moved.latitude, longitude: moved.longitude),
      label: old.label == GeoFileLayerBuilder.coordinateText(old.coordinate)
        ? GeoFileLayerBuilder.coordinateText(
          GeoCoordinate(latitude: moved.latitude, longitude: moved.longitude)) : old.label,
      accent: old.accent, glyph: old.glyph)

    onUpdatePin?(old, new)
  }

  /// A pin selected on the map is selected in the list too, without moving the map.
  func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
    guard let pin = view.annotation as? MapPinAnnotation, pin.isEditable else { return }

    pinList?.select(id: pin.pin.id)
  }

  /// Shows the editor for a file pin, over its marker when it is on screen.
  func showEditor(for annotation: MapPinAnnotation) {
    closeEditor()

    var used: [PinGlyph] = []

    for glyph in filePinsInOrder.compactMap(\.glyph) where !used.contains(glyph) {
      used.append(glyph)
    }

    let controller = PinEditorController(
      pin: annotation.pin, layerAccent: annotation.layerAccent, palette: palette, used: used)
    let popover = NSPopover()
    popover.contentViewController = controller
    popover.behavior = .transient
    popover.delegate = self

    controller.onDone = { [weak self] edited in
      self?.closeEditor()
      self?.onUpdatePin?(annotation.pin, edited)
    }
    controller.onCancel = { [weak self] in self?.closeEditor() }

    editor = (popover, controller)

    if let marker = mapView.view(for: annotation), marker.window != nil {
      popover.show(relativeTo: marker.bounds, of: marker, preferredEdge: .maxY)
    } else if window != nil {
      let center = NSRect(x: bounds.midX - 1, y: bounds.midY - 1, width: 2, height: 2)
      popover.show(relativeTo: center, of: self, preferredEdge: .maxY)
    }
  }

  func closeEditor() {
    editor?.popover.close()
    editor = nil
  }

  func popoverDidClose(_ notification: Notification) {
    if (notification.object as? NSPopover) === editor?.popover { editor = nil }
  }

  // MARK: Pin list

  var showsPinList: Bool { pinList != nil }

  /// Shows or hides the pin list at the map's trailing edge.
  func setPinList(visible: Bool) {
    guard visible != showsPinList else { return }

    if visible {
      let list = PinListView()
      list.translatesAutoresizingMaskIntoConstraints = false
      list.apply(palette)
      list.onSelect = { [weak self] id in self?.reveal(pinID: id) }
      list.onEdit = { [weak self] id in
        guard let self, let pin = annotation(forPinID: id) else { return }

        reveal(pinID: id)
        showEditor(for: pin)
      }
      list.onRemove = { [weak self] id in
        guard let self, let pin = annotation(forPinID: id) else { return }

        onRemovePin?(pin.pin)
      }
      list.onAdd = { [weak self] in self?.onAddPinAtCenter?() }
      addSubview(list)

      mapTrailing?.isActive = false
      let trailing = mapView.trailingAnchor.constraint(equalTo: list.leadingAnchor)

      NSLayoutConstraint.activate([
        trailing,
        list.trailingAnchor.constraint(equalTo: trailingAnchor),
        list.topAnchor.constraint(equalTo: topAnchor),
        list.bottomAnchor.constraint(equalTo: bottomAnchor),
      ])

      mapTrailing = trailing
      pinList = list
      list.show(pins: filePinsInOrder)
    } else {
      pinList?.removeFromSuperview()
      pinList = nil

      let trailing = mapView.trailingAnchor.constraint(equalTo: trailingAnchor)
      trailing.isActive = true
      mapTrailing = trailing
    }
  }

  private func annotation(forPinID id: String) -> MapPinAnnotation? {
    mapView.annotations.lazy.compactMap { $0 as? MapPinAnnotation }.first {
      $0.layer == .file && $0.pin.id == id
    }
  }

  /// Selects a pin and moves the map to it, as the user's own move.
  func reveal(pinID id: String) {
    guard let pin = annotation(forPinID: id) else { return }

    noteUserGesture()
    mapView.setCenter(pin.coordinate, animated: animatesCommands)
    mapView.selectAnnotation(pin, animated: animatesCommands)
  }

  // MARK: Place search

  /// Shows an empty place search over the top of the map and puts the keyboard in it. Each showing
  /// starts a new search, so the field never holds a stale query.
  func showPlaceSearch(makeSearcher: @MainActor () -> any PlaceSearching) {
    if placeSearch == nil {
      let search = PlaceSearchView(searcher: makeSearcher(), placeholder: "Go to place")
      search.translatesAutoresizingMaskIntoConstraints = false
      search.apply(palette)
      search.onPick = { [weak self] region, _ in self?.onPlacePicked?(region) }
      search.onEscapeEmpty = { [weak self] in self?.hidePlaceSearch() }
      search.onSubmitWithoutPlace = { [weak self] in self?.hidePlaceSearch() }
      addSubview(search)

      let preferredWidth = search.widthAnchor.constraint(equalToConstant: 460)
      preferredWidth.priority = .defaultHigh

      NSLayoutConstraint.activate([
        search.topAnchor.constraint(equalTo: topAnchor, constant: 12),
        search.centerXAnchor.constraint(equalTo: centerXAnchor),
        search.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
        search.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
        preferredWidth,
      ])

      placeSearch = search
    }

    layoutSubtreeIfNeeded()
    placeSearch?.focusField()
  }

  /// Takes the place search away. The keyboard goes back to the map when the search had it.
  func hidePlaceSearch() {
    guard let search = placeSearch else { return }

    let hadKeyboard = search.hasKeyboard

    search.stop()
    search.removeFromSuperview()
    placeSearch = nil

    if hadKeyboard { window?.makeFirstResponder(mapView) }
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
    var reason = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)

    while reason.hasSuffix(".") { reason.removeLast() }

    onTilesChanged?(
      "The map could not load: \(reason). The map needs a network connection to fetch its tiles.")
  }

  func mapViewDidFinishLoadingMap(_ mapView: MKMapView) {
    onTilesChanged?(nil)
  }

  // MARK: Pins

  /// Replaces every pin of `layer` with `pins`. The other layers keep theirs. A selected pin whose
  /// ID is still there stays selected.
  ///
  /// `isEditable` says which of a file layer's pins the user may change. Every other layer's pins
  /// are read-only.
  func replacePins(
    layer: MapLayer, pins: [GeoPin], defaultAccent: ThemeToken,
    isEditable: (GeoPin) -> Bool = { _ in true }
  ) {
    let selected = (mapView.selectedAnnotations.first as? MapPinAnnotation).flatMap {
      $0.layer == layer ? $0.pin.id : nil
    }

    removePins(layer: layer)

    let annotations = pins.map {
      MapPinAnnotation(
        pin: $0, layer: layer, layerAccent: defaultAccent,
        isEditable: layer == .file && isEditable($0))
    }

    mapView.addAnnotations(annotations)

    if let selected, let again = annotations.first(where: { $0.pin.id == selected }) {
      mapView.selectAnnotation(again, animated: false)
    }

    if layer == .file {
      filePinsInOrder = pins
      pinList?.show(pins: pins)
    }
  }

  func removePins(layer: MapLayer) {
    if layer == .file {
      filePinsInOrder = []
      pinList?.show(pins: [])
    }

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
      marker.onEdit = { [weak self] annotation in self?.showEditor(for: annotation) }
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

    notices.fillColor = palette[.mantle].nsColor
    noticesLabel.textColor = palette[.text].nsColor

    for marker in markers.allObjects { marker.palette = palette }

    placeSearch?.apply(palette)
    pinList?.apply(palette)
  }
}

/// A menu item that runs a closure, for menus built on the fly.
@MainActor
final class ClosureMenuItem: NSMenuItem {
  private let handler: @MainActor () -> Void

  init(_ title: String, handler: @escaping @MainActor () -> Void) {
    self.handler = handler
    super.init(title: title, action: #selector(run), keyEquivalent: "")
    target = self
  }

  @available(*, unavailable)
  required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

  @objc private func run() {
    handler()
  }

  /// Runs the item as a click would. A test calls it.
  func perform() {
    handler()
  }
}
