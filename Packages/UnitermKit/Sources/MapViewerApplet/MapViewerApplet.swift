import AppKit
import AppletKit
import GeoData
import StatusKit
import Theme

/// Shows a map that the user can pan and zoom, in one of three styles.
///
/// MapKit owns the map and its gestures. The applet keeps the visible region and the style in its
/// description, and `describe()` reads memory only. The region is saved when the map settles, not
/// at every frame.
@MainActor
public final class MapViewerApplet: Applet {
  public let typeID = MapViewerDescription.typeID
  public weak var host: (any AppletHost)?
  public let isRunningSomething = false

  public private(set) var title = MapViewerApplet.untitled
  public private(set) var segments: [AppletSegment] = []
  public private(set) var publishedTabs: AppletTabList

  private static let untitled = "Map"

  let content = MapViewerView()
  private var record: MapViewerDescription
  private var closed = false

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
    publishedTabs = AppletTabList(first: AppletTab(id: .make(), title: Self.untitled))

    wire()
    content.show(style: record.style)

    if let region = record.region {
      content.show(region: region)
    }

    refresh()
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

  // MARK: Applet

  public func start() {}

  public func close() {
    closed = true
    content.onRegionSettled = nil
    content.onLoadFailure = nil
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

    segments = [AppletSegment(symbolName: "map", text: Self.name(of: record.style))]
    content.setAccessibilityValue(accessibilitySummary())
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

    return text
  }
}
