import AppletKit
import GeoData

extension MapViewerApplet {
  /// The map opens GeoJSON as the owner. The system declares `public.geojson` and has it conform to
  /// `public.json`, so a `.geojson` file is more specific than the data viewer's JSON and routes
  /// here, while a plain `.json` file still goes to the data viewer.
  public nonisolated static let typeDeclaration = AppletTypeDeclaration(
    typeID: MapViewerDescription.typeID, displayName: "Map Viewer",
    opens: [OpenedType("public.geojson", rank: .owner)])

  /// The map viewer's own commands. Open has no key, since Cmd-O belongs to the window's File >
  /// Open, which routes by type. The three styles sit in the View menu with no keys.
  ///
  /// A command shows no check mark for the current style, since the registry has no state for a
  /// command. The status bar names the style instead.
  public static let commandSet = AppletCommandSet(
    typeID: MapViewerDescription.typeID, menuTitle: "Map",
    commands: [
      .openSource(),
      AppletCommand(
        name: "clear-file", title: "Clear File Pins", home: .file, section: 1,
        isAvailable: { ($0 as? MapViewerApplet)?.canClearFile ?? false },
        run: { applet in (applet as? MapViewerApplet)?.clearFile() }),
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
