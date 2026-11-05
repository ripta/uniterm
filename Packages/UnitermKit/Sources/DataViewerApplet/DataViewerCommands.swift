import AppletKit
import TableData

extension DataViewerApplet {
  /// The data viewer opens CSV and JSON files and is the default for both. A GeoJSON file goes to a
  /// map, whose type is more specific. TSV opens through the pane's own Open, and no type here
  /// routes to it.
  public nonisolated static let typeDeclaration = AppletTypeDeclaration(
    typeID: DataViewerDescription.typeID, displayName: "Data Viewer",
    opens: [
      OpenedType("public.comma-separated-values-text", rank: .owner),
      OpenedType("public.json", rank: .owner),
    ])

  /// The data viewer's own commands. Open has no key, since Cmd-O belongs to the window's File >
  /// Open, which routes by type.
  ///
  /// The find commands sit in Edit > Find, and all four are off until a file is loaded. Focus Filter
  /// has no key. The commands run in the pane whatever has focus, so they work from the filter field.
  public static let commandSet = AppletCommandSet(
    typeID: DataViewerDescription.typeID, menuTitle: "Data Viewer",
    commands: [
      .openSource(section: 1),
      .find(name: "find", title: "Find\u{2026}", key: KeyChord("f")) { $0.showFind() },
      .find(name: "find-next", title: "Find Next", key: KeyChord("g")) {
        $0.stepFind(forward: true)
      },
      .find(
        name: "find-previous", title: "Find Previous", key: KeyChord("g", [.command, .shift])
      ) { $0.stepFind(forward: false) },
      .find(name: "focus-filter", title: "Focus Filter", key: nil, section: 1) {
        $0.focusFilter()
      },
    ])
}

extension AppletCommand {
  fileprivate static func find(
    name: String, title: String, key: KeyChord?, section: Int = 0,
    run: @escaping @MainActor (DataViewerApplet) -> Void
  ) -> AppletCommand {
    AppletCommand(
      name: name, title: title, key: key, home: .editFind, section: section,
      isAvailable: { ($0 as? DataViewerApplet)?.hasTable ?? false },
      run: { applet in
        guard let viewer = applet as? DataViewerApplet else { return }

        run(viewer)
      })
  }
}
