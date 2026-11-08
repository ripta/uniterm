import AppletKit

extension TerminalApplet {
  /// The terminal opens a folder as a new pane started there, and it is the default for folders.
  /// A package is not a folder, so a bundle is not routed here.
  public nonisolated static let typeDeclaration = AppletTypeDeclaration(
    typeID: TerminalDescription.typeID, displayName: "Terminal", symbolName: "terminal",
    opens: [OpenedType("public.folder", rank: .owner)])
}
