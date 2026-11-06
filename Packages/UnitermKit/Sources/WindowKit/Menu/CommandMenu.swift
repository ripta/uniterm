import AppKit
import AppletKit

/// A menu item that runs a registry command. It carries the command's ID, so the item needs no
/// selector of its own. An item for an applet's command also names the applet type that owns it.
@MainActor
final class CommandMenuItem: NSMenuItem {
  let commandID: CommandID
  let ownerTypeID: String?

  init(_ command: Command) {
    commandID = command.id

    if case .applet(let typeID) = command.owner {
      ownerTypeID = typeID
    } else {
      ownerTypeID = nil
    }

    super.init(
      title: command.menu?.title ?? command.title,
      action: #selector(CommandMenu.performCommand(_:)), keyEquivalent: "")

    if ownerTypeID == nil, let key = command.key {
      keyEquivalent = key.key
      keyEquivalentModifierMask = key.modifiers
    }
  }

  @available(*, unavailable)
  required init(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  var isAppletItem: Bool { ownerTypeID != nil }
}

/// The main menu, generated from the command registry.
///
/// Every item of a registry command targets this object and names its command. uniterm's commands
/// have fixed homes. An applet's commands go where the applet says. Items for an applet type are
/// hidden unless the key window's focused pane runs that type, and they are disabled while a sheet
/// or the Settings window is key. The Edit menu holds the standard edit actions, which stay on the
/// responder chain. Below them it holds a Find submenu for applets that declare find commands.
///
/// The menu keeps the keys of the applet items in step with the keys uniterm reserves. It reads the
/// reserved keys from the live items, so a user's App Shortcuts remap of a uniterm item takes its
/// reservation with it. The keys are read when the menu installs, when the user defaults change,
/// when the app becomes active, and before each Command-key press that the window routes.
@MainActor
public final class CommandMenu: NSObject, NSMenuItemValidation {
  public let menu = NSMenu()

  private let registry: CommandRegistry
  /// The window that app commands follow when none is key, such as while Settings is key.
  private let activeController: @MainActor () -> MainWindowController?
  private var appletItems: [CommandMenuItem] = []
  private var appletMenus: [String: NSMenuItem] = [:]
  private var findMenu: (separator: NSMenuItem, find: NSMenuItem)?
  private var windowMenu = NSMenu(title: "Window")
  private var lastReserved: Set<KeyChord>?
  private var observers: [any NSObjectProtocol] = []

  /// The window whose focused pane the menus follow. Tests replace it.
  var keyController: @MainActor () -> MainWindowController? = {
    NSApp.keyWindow?.windowController as? MainWindowController
  }

  /// The key window, whatever kind. Close acts on it when no main window is key.
  var keyWindow: @MainActor () -> NSWindow? = { NSApp.keyWindow }

  public init(
    registry: CommandRegistry, activeController: @escaping @MainActor () -> MainWindowController?
  ) {
    self.registry = registry
    self.activeController = activeController
    super.init()

    build()
  }

  isolated deinit {
    for observer in observers {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  // MARK: Install

  /// Makes this the app's main menu and starts following the key window and the user's shortcuts.
  public func install() {
    registry.menu = self
    NSApp.mainMenu = menu
    NSApp.windowsMenu = windowMenu

    let center = NotificationCenter.default
    let names: [Notification.Name] = [
      NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
      NSApplication.didBecomeActiveNotification, UserDefaults.didChangeNotification,
    ]

    observers = names.map { name in
      center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.sync() }
      }
    }

    refreshKeys()
    sync()
  }

  // MARK: Build

  private func build() {
    menu.addItem(submenuItem(NSMenu(), home: .app))
    menu.addItem(submenuItem(NSMenu(title: "File"), home: .file))
    menu.addItem(editMenuItem())
    menu.addItem(submenuItem(NSMenu(title: "View"), home: .view))

    for set in registry.appletSets {
      let commands = registry.commands.filter {
        $0.owner == .applet(typeID: set.typeID) && $0.menu?.home == .applet
      }

      guard !commands.isEmpty else { continue }

      let item = NSMenuItem()
      item.submenu = NSMenu(title: set.menuTitle)
      fill(item.submenu, with: commands)
      menu.addItem(item)
      appletMenus[set.typeID] = item
    }

    windowMenu = NSMenu(title: "Window")

    let window = NSMenuItem()
    window.submenu = windowMenu
    fill(windowMenu, with: commands(for: .window))
    menu.addItem(window)
  }

  private func submenuItem(_ submenu: NSMenu, home: MenuHome) -> NSMenuItem {
    let item = NSMenuItem()
    item.submenu = submenu
    fill(submenu, with: commands(for: home))
    return item
  }

  private func commands(for home: MenuHome) -> [Command] {
    registry.commands.filter { $0.menu?.home == home }
  }

  /// Adds the commands in section order, with a separator between sections. Within a section an
  /// applet's commands come before uniterm's, so New Tab leads the split items.
  private func fill(_ target: NSMenu?, with commands: [Command]) {
    guard let target else { return }

    let ordered = commands.enumerated().sorted { lhs, rhs in
      let (left, right) = (lhs.element, rhs.element)
      let sections = (left.menu?.section ?? 0, right.menu?.section ?? 0)

      if sections.0 != sections.1 { return sections.0 < sections.1 }

      if left.owner != right.owner { return left.owner != .uniterm }

      return lhs.offset < rhs.offset
    }

    var previous: Int?

    for (_, command) in ordered {
      let section = command.menu?.section ?? 0

      if let previous, previous != section {
        target.addItem(.separator())
      }

      previous = section

      let item = CommandMenuItem(command)
      item.target = self
      target.addItem(item)

      if item.isAppletItem {
        appletItems.append(item)
      }
    }
  }

  private func editMenuItem() -> NSMenuItem {
    let item = NSMenuItem()
    let edit = NSMenu(title: "Edit")

    edit.addItem(
      withTitle: "Undo", action: #selector(MainWindow.undoEdit(_:)), keyEquivalent: "z")

    let redo = NSMenuItem(
      title: "Redo", action: #selector(MainWindow.redoEdit(_:)), keyEquivalent: "z")
    redo.keyEquivalentModifierMask = [.command, .shift]
    edit.addItem(redo)
    edit.addItem(.separator())
    edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(
      withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

    let findCommands = commands(for: .editFind)

    if !findCommands.isEmpty {
      let separator = NSMenuItem.separator()
      let find = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
      find.submenu = NSMenu(title: "Find")
      fill(find.submenu, with: findCommands)

      edit.addItem(separator)
      edit.addItem(find)
      findMenu = (separator: separator, find: find)
    }

    item.submenu = edit
    return item
  }

  // MARK: Keys

  /// The keys uniterm reserves: every key on an item that is not an applet's, whether the item is
  /// shown or not, in the live menu. That covers uniterm's window commands after the user's
  /// remaps, the Edit items, and whatever AppKit added to the menus.
  func reservedKeys() -> Set<KeyChord> {
    var keys = KeyReservations.editKeys
    collectReserved(menu, into: &keys)
    return keys
  }

  private func collectReserved(_ menu: NSMenu, into keys: inout Set<KeyChord>) {
    for item in menu.items {
      if let submenu = item.submenu {
        collectReserved(submenu, into: &keys)
      }

      if (item as? CommandMenuItem)?.isAppletItem == true { continue }

      if !item.keyEquivalent.isEmpty {
        keys.insert(KeyChord(item.keyEquivalent, item.keyEquivalentModifierMask))
      }
    }
  }

  /// Gives each applet item the key it holds now. An item with a user's remap keeps the remap.
  func refreshKeys() {
    let reserved = reservedKeys()
    lastReserved = reserved

    registry.resolveKeys(reserved: reserved)

    for item in appletItems where item.userKeyEquivalent.isEmpty {
      let key = registry.appletKeys[item.commandID]
      let wanted = key?.key ?? ""
      let mask = key?.modifiers ?? []

      if item.keyEquivalent != wanted { item.keyEquivalent = wanted }

      if item.keyEquivalentModifierMask != mask { item.keyEquivalentModifierMask = mask }
    }
  }

  /// The live key of a command's item, as the menu shows it now.
  func keyEquivalent(of id: CommandID) -> (key: String, modifiers: NSEvent.ModifierFlags)? {
    func find(in menu: NSMenu) -> NSMenuItem? {
      for item in menu.items {
        if (item as? CommandMenuItem)?.commandID == id { return item }

        if let submenu = item.submenu, let found = find(in: submenu) { return found }
      }

      return nil
    }

    guard let item = find(in: menu) else { return nil }

    return (item.keyEquivalent, item.keyEquivalentModifierMask)
  }

  // MARK: State

  /// Shows the items of the applet type the key window's focused pane runs, and hides the rest. It
  /// also rereads the reserved keys when the live menu changed them.
  public func sync() {
    let shown = (keyController() ?? activeController())?.activeAppletTypeID

    for item in appletItems {
      let hidden = item.ownerTypeID != shown

      if item.isHidden != hidden { item.isHidden = hidden }
    }

    for (typeID, item) in appletMenus {
      let hidden = typeID != shown

      if item.isHidden != hidden { item.isHidden = hidden }
    }

    if let findMenu {
      let hidden = !(findMenu.find.submenu?.items ?? []).contains {
        ($0 as? CommandMenuItem)?.ownerTypeID == shown
      }

      if findMenu.find.isHidden != hidden {
        findMenu.find.isHidden = hidden
        findMenu.separator.isHidden = hidden
      }
    }

    if reservedKeys() != lastReserved {
      refreshKeys()
    }
  }

  public func validateMenuItem(_ item: NSMenuItem) -> Bool {
    guard let item = item as? CommandMenuItem else { return true }

    let controller = keyController()

    if item.commandID == .close, controller == nil {
      return closableOtherWindow != nil
    }

    if item.commandID == .toggleMessageHistory, let controller {
      item.title = controller.historyVisible ? "Hide Message History" : "Show Message History"
    }

    let context = controller?.commandContext() ?? CommandContext(controller: nil, pane: nil)
    return registry.isAvailable(item.commandID, in: context)
  }

  @objc func performCommand(_ sender: Any?) {
    guard let item = sender as? CommandMenuItem, let command = registry.command(item.commandID)
    else { return }

    if command.scope == .app {
      if let controller = activeController() {
        controller.dispatch(item.commandID)
      } else {
        registry.runWithoutWindow(item.commandID)
      }
    } else if let controller = keyController() {
      controller.dispatch(item.commandID)
    } else if item.commandID == .close {
      closableOtherWindow?.performClose(nil)
    }
  }

  /// The key window when it is not a main window, such as Settings, and it can close. Cmd-W closes
  /// it, so the key is not dead there. A sheet is not closable this way. It answers its own
  /// question.
  private var closableOtherWindow: NSWindow? {
    guard let window = keyWindow(), window.sheetParent == nil, window.styleMask.contains(.closable)
    else { return nil }

    return window
  }
}
