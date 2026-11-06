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
  /// Open, which routes by type. The three styles sit in the View menu on Cmd-1 to Cmd-3. A map has
  /// no tabs, and the terminal's tab keys are hidden while a map pane has focus.
  ///
  /// Zoom In, Zoom Out, and Zoom to Fit Pins take the keys the terminal uses for its text size,
  /// since each applet's keys apply only while its pane has focus.
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
      .style(.standard, name: "style-standard", title: "Standard Map", key: KeyChord("1")),
      .style(.satellite, name: "style-satellite", title: "Satellite Map", key: KeyChord("2")),
      .style(.hybrid, name: "style-hybrid", title: "Hybrid Map", key: KeyChord("3")),
      .view(name: "zoom-in", title: "Zoom In", key: KeyChord("+")) { $0.content.zoom(closerBy: 2) },
      .view(name: "zoom-out", title: "Zoom Out", key: KeyChord("-")) {
        $0.content.zoom(closerBy: 0.5)
      },
      .view(
        name: "zoom-to-pins", title: "Zoom to Fit Pins", key: KeyChord("0"),
        isAvailable: { $0.canFitPins }
      ) { $0.fitPins() },
      .view(
        name: "face-north", title: "Face North", key: KeyChord("n", [.command, .shift]),
        isAvailable: { $0.content.isTurned }
      ) { $0.content.faceNorth() },
      .view(
        name: "go-to-place", title: "Go to Place\u{2026}", key: KeyChord("l"),
        isAvailable: { $0.canGoToPlace }
      ) { $0.showPlaceSearch() },
    ])
}

extension AppletCommand {
  fileprivate static func style(
    _ style: MapStyle, name: String, title: String, key: KeyChord
  ) -> AppletCommand {
    AppletCommand(
      name: name, title: title, key: key, home: .view, section: 2,
      run: { applet in
        guard let map = applet as? MapViewerApplet else { return }

        map.choose(style: style)
      })
  }

  /// A View menu command on the map's camera. It is off while the pane is not a map.
  fileprivate static func view(
    name: String, title: String, key: KeyChord,
    isAvailable: @escaping @MainActor (MapViewerApplet) -> Bool = { _ in true },
    run: @escaping @MainActor (MapViewerApplet) -> Void
  ) -> AppletCommand {
    AppletCommand(
      name: name, title: title, key: key, home: .view, section: 3,
      isAvailable: { applet in (applet as? MapViewerApplet).map(isAvailable) ?? false },
      run: { applet in
        guard let map = applet as? MapViewerApplet else { return }

        run(map)
      })
  }
}
