import AppletKit

extension TerminalApplet {
  /// The terminal opens a folder as a new pane started there, and it is the default for folders.
  /// A package is not a folder, so a bundle is not routed here.
  ///
  /// A terminal may be remote-controlled, with no driver. It takes no applet commands, and its
  /// input cannot be injected, so control reaches it only as the host API's pane calls.
  public nonisolated static let typeDeclaration = AppletTypeDeclaration(
    typeID: TerminalDescription.typeID, displayName: "Terminal", symbolName: "terminal",
    opens: [OpenedType("public.folder", rank: .owner)],
    controlSupport: [.disconnected, .remoteControlled])
}
