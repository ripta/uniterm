import AppletKit
import GeoData

extension MapViewerApplet {
  /// The map opens no content type yet, so no file routes to it. It is listed so the launcher and
  /// the catalog know the type.
  public nonisolated static let typeDeclaration = AppletTypeDeclaration(
    typeID: MapViewerDescription.typeID, displayName: "Map Viewer", opens: [])

  /// The map viewer's own commands. The three styles sit in the View menu with no keys.
  ///
  /// A command shows no check mark for the current style, since the registry has no state for a
  /// command. The status bar names the style instead.
  public static let commandSet = AppletCommandSet(
    typeID: MapViewerDescription.typeID, menuTitle: "Map",
    commands: [
      .style(.standard, name: "style-standard", title: "Standard Map"),
      .style(.satellite, name: "style-satellite", title: "Satellite Map"),
      .style(.hybrid, name: "style-hybrid", title: "Hybrid Map"),
    ])
}

extension AppletCommand {
  fileprivate static func style(_ style: MapStyle, name: String, title: String) -> AppletCommand {
    AppletCommand(
      name: name, title: title, home: .view, section: 2,
      run: { applet in
        guard let map = applet as? MapViewerApplet else { return }

        map.choose(style: style)
      })
  }
}
