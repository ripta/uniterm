import AppletKit
import BrowserModel

extension BrowserApplet {
  /// The browser opens no file. `file:` never loads, and the text viewer owns local files, so the
  /// router sends nothing here and the app declares no document type for it.
  public nonisolated static let typeDeclaration = AppletTypeDeclaration(
    typeID: BrowserDescription.typeID, displayName: "Browser", opens: [])

  /// The browser's own commands. Back and Forward sit in the applet menu with no key, since Cmd-[
  /// and Cmd-] are uniterm's pane keys. Reload and Open Location take the keys other browsers use.
  public static let commandSet = AppletCommandSet(
    typeID: BrowserDescription.typeID, menuTitle: "Browser",
    commands: [
      AppletCommand(
        name: "open-location", title: "Open Location", key: KeyChord("l"), home: .file,
        isAvailable: { $0 is BrowserApplet },
        run: { ($0 as? BrowserApplet)?.openLocation() }),
      AppletCommand(
        name: "reload", title: "Reload", key: KeyChord("r"), home: .view,
        isAvailable: { $0 is BrowserApplet },
        run: { ($0 as? BrowserApplet)?.reload() }),
      AppletCommand(
        name: "back", title: "Back", home: .applet,
        isAvailable: { ($0 as? BrowserApplet)?.canGoBack ?? false },
        run: { ($0 as? BrowserApplet)?.goBack() }),
      AppletCommand(
        name: "forward", title: "Forward", home: .applet,
        isAvailable: { ($0 as? BrowserApplet)?.canGoForward ?? false },
        run: { ($0 as? BrowserApplet)?.goForward() }),
    ])
}
