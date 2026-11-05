import AppKit
import AppletKit
import GeoData
import SourceAccess
import StatusKit
import Theme

/// Shows a map that the user can pan and zoom, in one of three styles, with the pins of a GeoJSON
/// file on it.
///
/// MapKit owns the map and its gestures. The applet keeps the visible region and the style in its
/// description, and `describe()` reads memory only. The region is saved when the map settles, not
/// at every frame.
///
/// Every file load goes through `replaceSource`. The open panel, a drop, the router, and a restore
/// reach the same path, which finds the file and parses it off the main thread. The file's pins are
/// their own layer, so loading another file replaces them and nothing else. The description holds
/// the file's path and bookmark, never its pins.
@MainActor
public final class MapViewerApplet: Applet, SourceReplacing {
  public let typeID = MapViewerDescription.typeID
  public weak var host: (any AppletHost)?
  public let isRunningSomething = false

  public private(set) var title = MapViewerApplet.untitled
  public private(set) var segments: [AppletSegment] = []
  public private(set) var publishedTabs: AppletTabList

  private static let untitled = "Map"
  private static let limits = GeoJSONLimits()

  let content = MapViewerView()
  private var record: MapViewerDescription
  private var closed = false
  private(set) var opening: Task<Void, Never>?
  private var openGeneration = 0
  private var restoreWaitsForStart = false
  private var filePins: [GeoPin] = []
  private var fileNotices: [String] = []
  private var fileFailure: String?
  private var resolvedNotice: String?

  /// An empty pane that starts in `startDirectory`. The directory is explicit, and the applet never
  /// reads it from another pane.
  public init(startDirectory: String?) {
    record = MapViewerDescription(startDirectory: startDirectory)
    publishedTabs = AppletTabList(first: AppletTab(id: .make(), title: Self.untitled))

    wire()
    refresh()
  }

  /// Restores a pane from its description. The region and style come back with no work on the
  /// disk or the network. A description this build cannot read is refused.
  public init(restoring description: AppletDescription) throws {
    record = try MapViewerDescription.decode(description)
    restoreWaitsForStart = record.path != nil
    publishedTabs = AppletTabList(first: AppletTab(id: .make(), title: Self.untitled))

    wire()
    content.show(style: record.style)

    if let region = record.region {
      content.show(region: region)
    }

    refresh()
  }

  /// The factory behind the router and the launcher: a pane that starts in `startDirectory` and
  /// opens `file`.
  public static func opening(_ file: URL, startDirectory: String) -> MapViewerApplet {
    let applet = MapViewerApplet(startDirectory: startDirectory)
    applet.replaceSource(with: file, startDirectory: startDirectory)

    return applet
  }

  public var view: NSView { content }

  /// The open file's folder, or else the directory the pane started in.
  public var currentDirectory: String? {
    if let path = record.path {
      let folder = (path as NSString).deletingLastPathComponent

      if Self.isDirectory(folder) { return folder }
    }

    if let start = record.startDirectory, Self.isDirectory(start) { return start }

    return nil
  }

  private static func isDirectory(_ path: String) -> Bool {
    var isDirectory: ObjCBool = false

    return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
      && isDirectory.boolValue
  }

  private func wire() {
    content.onRegionSettled = { [weak self] region in self?.regionSettled(region) }
    content.onLoadFailure = { [weak self] text in
      guard let self else { return }

      self.host?.applet(self, post: .warning, text: text)
    }
    content.onDrop = { [weak self] urls in self?.handleDrop(urls) ?? false }
  }

  // MARK: Style

  /// The style the pane shows.
  public var style: MapStyle { record.style }

  /// Shows the map in `style`. The choice is in the description at once, so a reopen or a
  /// relaunch brings it back.
  func choose(style: MapStyle) {
    guard style != record.style else { return }

    record.style = style
    content.show(style: style)
    refresh()
    host?.appletDidChange(self)
  }

  // MARK: Region

  private func regionSettled(_ region: GeoRegion) {
    if let stored = record.region, stored.isIndistinguishable(from: region) { return }

    record.region = region
    refresh()
    host?.appletDidChange(self)
  }

  /// True when the file layer has pins for Zoom to Fit Pins to show.
  var canFitPins: Bool { !filePins.isEmpty }

  /// Shows every pin of the file layer, as a load does, and saves that region with the pane.
  func fitPins() {
    guard let region = GeoRegion.fitting(filePins.map(\.coordinate)) else { return }

    content.show(region: region)
    regionSettled(region)
  }

  // MARK: Source

  /// Shows the pins of `file` in place of the file layer's. The pins on the map go at once. The new
  /// file is found and parsed off the main thread, and a failure shows its message in the pane.
  /// The map then fits the new pins, and that region is saved with the pane.
  ///
  /// `SourceReplacing` lets a viewer throw. This one never does, since every failure shows in the
  /// pane once the load runs.
  public func replaceSource(with file: URL, startDirectory: String) {
    record.startDirectory = startDirectory
    record.path = file.path
    record.bookmark = nil
    restoreWaitsForStart = false

    open(path: file.path, bookmark: nil, fitsPins: true)
  }

  private func open(path: String, bookmark: Data?, fitsPins: Bool) {
    opening?.cancel()
    openGeneration += 1
    resolvedNotice = nil
    fileFailure = nil
    fileNotices = []
    filePins = []
    content.removePins(layer: .file)

    let generation = openGeneration
    let limits = Self.limits

    opening = Task { [weak self] in
      let resolved = await SourceResolver.resolve(path: path, bookmark: bookmark)

      guard let self, generation == self.openGeneration, !self.closed else { return }

      switch resolved {
      case .failure(let error):
        self.finishOpen(failure: error.errorDescription)

      case .success(let source):
        self.record.bookmark = source.bookmark

        if source.movedFrom != nil {
          self.record.path = source.file.path
          self.resolvedNotice = "Moved. Found at \(source.file.path)."
        }

        let result = await GeoJSONFileReader.read(source.file, limits: limits)

        guard generation == self.openGeneration, !self.closed else { return }

        switch result {
        case .failure(let error):
          self.finishOpen(failure: error.errorDescription)

        case .success(let layer):
          self.finishOpen(layer: layer, fitsPins: fitsPins)
        }
      }
    }
  }

  private func finishOpen(failure: String?) {
    opening = nil
    fileFailure = failure ?? "The file could not be opened."
    refresh()
    host?.appletDidChange(self)
  }

  private func finishOpen(layer: GeoFileLayer, fitsPins: Bool) {
    opening = nil
    filePins = layer.pins
    fileNotices = layer.notices(limit: Self.limits.maxPoints)

    if layer.pins.isEmpty && layer.skippedShapes == 0 && layer.invalidCoordinates == 0 {
      fileNotices.append("The file has no points to show.")
    }

    let accent = fileAccent

    record.fileAccent = accent.rawValue
    content.replacePins(layer: .file, pins: layer.pins, defaultAccent: accent)

    if fitsPins, let region = GeoRegion.fitting(layer.pins.map(\.coordinate)) {
      record.region = region
      content.show(region: region)
    }

    refresh()
    host?.appletDidChange(self)
  }

  /// The file layer's default accent: the stored one while it names an accent, else the first of
  /// the fixed order. The layer keeps it for the pane's life, even after a clear.
  var fileAccent: ThemeToken {
    PinAccents.validated(record.fileAccent) ?? PinAccents.layerDefault(at: 0)
  }

  /// The pins the file layer shows now.
  var filePinsShown: [GeoPin] { filePins }

  /// True when the file layer holds pins or names a file, which is when Clear File Pins has work.
  var canClearFile: Bool { record.path != nil || !filePins.isEmpty || fileFailure != nil }

  /// Removes the file layer's pins and forgets the file, so a relaunch does not bring them back.
  /// The layer keeps its default accent.
  func clearFile() {
    opening?.cancel()
    opening = nil
    openGeneration += 1
    restoreWaitsForStart = false
    resolvedNotice = nil
    fileFailure = nil
    fileNotices = []
    filePins = []
    record.path = nil
    record.bookmark = nil
    content.removePins(layer: .file)

    refresh()
    host?.appletDidChange(self)
  }

  /// A drop of one file replaces the file layer. Several files are refused with a message, and the
  /// pane keeps what it showed.
  func handleDrop(_ urls: [URL]) -> Bool {
    guard let file = urls.first else { return false }

    guard urls.count == 1 else {
      host?.applet(
        self, post: .warning, text: "Drop one file at a time. The map shows one file in a pane.")
      return false
    }

    replaceSource(with: file, startDirectory: SourceStartDirectory.of(file))

    return true
  }

  // MARK: Applet

  public func start() {
    guard restoreWaitsForStart, let path = record.path else { return }

    restoreWaitsForStart = false
    open(path: path, bookmark: record.bookmark, fitsPins: false)
  }

  public func close() {
    closed = true
    opening?.cancel()
    opening = nil
    content.onRegionSettled = nil
    content.onLoadFailure = nil
    content.onDrop = nil
    content.stopObserving()
    content.mapView.delegate = nil
  }

  public func detach() {}

  public func reattach() {}

  public func focus() {
    content.window?.makeFirstResponder(content.mapView)
  }

  public func apply(_ palette: ThemePalette) {
    content.apply(palette)
  }

  public func describe() -> AppletDescription {
    // The payload always encodes. The fields are plain values, so a failure is a programming error.
    // A release build falls back to an empty payload, which restores as a default map.
    if let description = try? record.appletDescription() { return description }

    assertionFailure("the map viewer description failed to encode")

    return AppletDescription(
      type: MapViewerDescription.typeID, version: MapViewerDescription.currentVersion,
      payload: .object([:]))
  }

  // MARK: Display

  private func refresh() {
    guard !closed else { return }

    var newSegments = [AppletSegment(symbolName: "map", text: Self.name(of: record.style))]

    if !filePins.isEmpty {
      newSegments.append(
        AppletSegment(
          symbolName: "mappin",
          text: filePins.count == 1 ? "1 pin" : "\(filePins.count.formatted()) pins"))
    }

    segments = newSegments

    var lines: [String] = []

    if let fileFailure { lines.append(fileFailure) }

    if opening != nil { lines.append("Opening\u{2026}") }

    lines += fileNotices

    if let resolvedNotice { lines.append(resolvedNotice) }

    content.show(notices: lines)
    content.setAccessibilityValue(accessibilitySummary())

    let newTitle = record.path.map { ($0 as NSString).lastPathComponent } ?? Self.untitled

    if newTitle != title {
      title = newTitle
      publishedTabs = AppletTabList(first: AppletTab(id: publishedTabs.first.id, title: newTitle))
      host?.appletTabsDidChange(self)
    }
  }

  private static func name(of style: MapStyle) -> String {
    switch style {
    case .standard: return "Standard"
    case .satellite: return "Satellite"
    case .hybrid: return "Hybrid"
    }
  }

  /// The style and the center of the saved region, to two places. A UI test and an assistive tool
  /// read it, since the map view itself says little.
  private func accessibilitySummary() -> String {
    var text = record.style.rawValue

    if let center = record.region?.center {
      text += String(format: " %.2f,%.2f", center.latitude, center.longitude)
    }

    if !filePins.isEmpty { text += " pins=\(filePins.count)" }

    return text
  }
}
