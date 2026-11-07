import AppletKit
import UniformTypeIdentifiers

extension ImageViewerApplet {
  /// The image viewer opens images as the owner and folders as an alternate, since the terminal is
  /// the default for a folder.
  public nonisolated static let typeDeclaration = AppletTypeDeclaration(
    typeID: ImageViewerDescription.typeID, displayName: "Image Viewer", symbolName: "photo",
    opens: [
      OpenedType("public.image", rank: .owner),
      OpenedType("public.folder", rank: .alternate),
    ])

  /// The image viewer's own commands. Open has no key, since Cmd-O belongs to the window's File >
  /// Open, which routes by type.
  public static let commandSet = AppletCommandSet(
    typeID: ImageViewerDescription.typeID, menuTitle: "Image Viewer",
    commands: [
      .openSource(section: 1)
    ])
}
