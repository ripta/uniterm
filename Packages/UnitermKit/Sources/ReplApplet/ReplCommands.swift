import AppKit
import AppletKit

extension ReplApplet {
  /// The REPL declares no content type. A user opens it from the launcher. It may be
  /// remote-controlled with no driver, as a terminal may, and takes no applet commands.
  public nonisolated static let typeDeclaration = AppletTypeDeclaration(
    typeID: ReplDescription.typeID, displayName: "REPL", symbolName: "curlybraces", opens: [],
    controlSupport: [.disconnected, .remoteControlled])

  /// Restart shows only while the helper has gone, and it is the same action as the pane's button.
  /// Restarting with capabilities shows while a helper runs, and asks which ones the fresh helper
  /// gets. Both are always the user's actions.
  public static let commandSet = AppletCommandSet(
    typeID: ReplDescription.typeID, menuTitle: "REPL",
    commands: [
      AppletCommand(
        name: "restart", title: "Restart REPL", home: .applet,
        isAvailable: { ($0 as? ReplApplet)?.isEnded == true },
        run: { ($0 as? ReplApplet)?.restart() }),
      AppletCommand(
        name: "restart-with-capabilities", title: "Restart REPL with Capabilities\u{2026}",
        home: .applet,
        isAvailable: { ($0 as? ReplApplet)?.isEnded == false },
        run: { ($0 as? ReplApplet)?.showCapabilityRestartSheet() }),
    ])
}
