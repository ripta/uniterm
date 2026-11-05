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
  public static let commandSet = AppletCommandSet(
    typeID: DataViewerDescription.typeID, menuTitle: "Data Viewer",
    commands: [.openSource(section: 1)])
}
