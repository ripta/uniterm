import AppKit

/// Where an applet's command sits in the menu bar.
public enum AppletMenuHome: Sendable {
  case file
  case view
  case window

  /// The Find submenu of the Edit menu. It holds the find commands of whichever viewer has focus.
  /// The standard edit actions stay fixed items of Edit, and an applet places only find commands
  /// here. The submenu shows only while the focused applet has such commands.
  case editFind

  /// A menu named for the applet type. It shows only while the focused applet has such commands.
  case applet
}

/// One thing an applet type lets the user do, such as opening a tab or clearing the screen.
///
/// The host builds a registry entry, a menu item, and a palette entry from it. The run action
/// receives the applet it acts on and keeps no reference to it, so a command never holds an applet
/// open after the applet closes.
@MainActor
public struct AppletCommand {
  /// The command's name within its applet type, such as `clear`. The host namespaces it with the
  /// type, so the ID is `terminal.clear`. A name is never reused for a different action.
  public let name: String

  /// The title of the menu item and the palette entry. A user's App Shortcuts remap matches the
  /// item by this title, so a change of title drops the remap.
  public let title: String

  /// The key the command asks for. The host drops it when uniterm reserves it or another command
  /// of the same applet asks for it too. The command keeps working from its menu item.
  public let key: KeyChord?

  public let home: AppletMenuHome

  /// Commands of one menu with different sections are set apart by a separator.
  public let section: Int

  /// False for a command that the palette must not list, such as a tab selected by its number.
  public let listedInPalette: Bool

  public let isAvailable: @MainActor (any Applet) -> Bool
  public let run: @MainActor (any Applet) -> Void

  public init(
    name: String, title: String, key: KeyChord? = nil, home: AppletMenuHome, section: Int = 0,
    listedInPalette: Bool = true,
    isAvailable: @escaping @MainActor (any Applet) -> Bool = { _ in true },
    run: @escaping @MainActor (any Applet) -> Void
  ) {
    self.name = name
    self.title = title
    self.key = key
    self.home = home
    self.section = section
    self.listedInPalette = listedInPalette
    self.isAvailable = isAvailable
    self.run = run
  }
}

/// Every command of one applet type.
@MainActor
public struct AppletCommandSet {
  /// The applet type, as `Applet.typeID` spells it. It namespaces the command IDs.
  public let typeID: String

  /// What the applet is called in a warning, and the title of its menu.
  public let menuTitle: String

  public let commands: [AppletCommand]

  public init(typeID: String, menuTitle: String, commands: [AppletCommand]) {
    self.typeID = typeID
    self.menuTitle = menuTitle
    self.commands = commands
  }
}
