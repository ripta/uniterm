import AppKit
import AppletKit
import XCTest

@testable import WindowKit

/// The menus the registry generates, the keys applets may hold, and the Cmd-W question. The real
/// key window, App Shortcuts remaps, and the field editor need the app, so the UI tests cover them.
@MainActor
final class CommandMenuTests: XCTestCase {
  private var fixture: WindowFixture!
  private var controller: MainWindowController { fixture.controller }
  private var warnings: [String] = []
  private var savedMenu: NSMenu?
  private var installed: CommandMenu?

  override func setUp() async throws {
    fixture = try WindowFixture()
    savedMenu = NSApp.mainMenu
    warnings = []
  }

  override func tearDown() async throws {
    NSApp.mainMenu = savedMenu
    fixture.cleanUp()
  }

  private func registry(extra: [AppletCommandSet] = []) -> CommandRegistry {
    let registry = CommandRegistry(
      app: AppCommandHooks(warn: { [unowned self] in warnings.append($0) }))
    registry.register(FakeApplet.commandSet)

    for set in extra { registry.register(set) }

    return registry
  }

  private func item(_ id: CommandID, in menu: CommandMenu) throws -> CommandMenuItem {
    func find(in menu: NSMenu) -> CommandMenuItem? {
      for item in menu.items {
        if let found = item as? CommandMenuItem, found.commandID == id { return found }

        if let submenu = item.submenu, let found = find(in: submenu) { return found }
      }

      return nil
    }

    return try XCTUnwrap(find(in: menu.menu), "no menu item for \(id)")
  }

  private func titles(_ menu: NSMenu?) -> [String] {
    menu?.items.filter { !$0.isHidden && !$0.isSeparatorItem }.map(\.title) ?? []
  }

  private func topMenu(_ title: String, in menu: CommandMenu) -> NSMenuItem? {
    menu.menu.items.first { $0.submenu?.title == title }
  }

  // MARK: Menu generation

  /// Catches a menu that is not generated from the registry: Close keeps its fixed title, text size
  /// sits in View, New Tab in File, and Clear in the applet's own menu. Edit gains Cut and Redo.
  func testItemsLandInTheirHomesWithTheirKeptTitles() throws {
    let menu = CommandMenu(
      registry: controller.commands, activeController: { [controller] in controller })
    menu.keyController = { [controller] in controller }
    menu.sync()

    XCTAssertEqual(try item(.close, in: menu).title, "Close")
    XCTAssertEqual(try item(.close, in: menu).menu?.title, "File")
    XCTAssertEqual(try item(.fakeNewTab, in: menu).menu?.title, "File")
    XCTAssertEqual(try item(.fakeBiggerText, in: menu).menu?.title, "View")
    XCTAssertEqual(try item(.fakeClear, in: menu).menu?.title, "Fake")
    XCTAssertEqual(try item(.fakeClear, in: menu).title, "Clear Screen")

    let edit = try XCTUnwrap(topMenu("Edit", in: menu)?.submenu)
    let keys = edit.items.map {
      "\($0.title) \($0.keyEquivalent) \($0.keyEquivalentModifierMask.contains(.shift))"
    }

    XCTAssertTrue(keys.contains("Redo z true"), "\(keys)")
    XCTAssertTrue(keys.contains("Cut x false"), "\(keys)")
    XCTAssertTrue(keys.contains("Paste v false"), "\(keys)")
    XCTAssertFalse(edit.items.contains { $0 is CommandMenuItem }, "edit actions are commands")

    let actions = Dictionary(
      uniqueKeysWithValues: edit.items.filter { !$0.isSeparatorItem }.map { ($0.title, $0.action) })
    XCTAssertEqual(actions["Copy"], #selector(NSText.copy(_:)), "the terminal view answers copy:")
    XCTAssertEqual(actions["Paste"], #selector(NSText.paste(_:)))
    XCTAssertEqual(actions["Select All"], #selector(NSText.selectAll(_:)))
    XCTAssertEqual(actions["Cut"], #selector(NSText.cut(_:)))
    XCTAssertNil(
      edit.items.first { $0.title == "Copy" }?.target, "edit items stay on the responder chain")
  }

  /// Catches the applet menu showing for a pane that does not run that applet type, and the applet
  /// items staying live under another applet.
  func testAppletItemsShowOnlyForTheFocusedAppletType() throws {
    let menu = CommandMenu(
      registry: controller.commands, activeController: { [controller] in controller })
    menu.keyController = { [controller] in controller }
    menu.sync()

    XCTAssertFalse(try XCTUnwrap(topMenu("Fake", in: menu)).isHidden)
    XCTAssertFalse(try item(.fakeNewTab, in: menu).isHidden)

    controller.openLauncher(axis: .row)
    menu.sync()

    XCTAssertTrue(try XCTUnwrap(topMenu("Fake", in: menu)).isHidden)
    XCTAssertTrue(try item(.fakeNewTab, in: menu).isHidden)
    XCTAssertTrue(try item(.fakeTab(1), in: menu).isHidden)
    XCTAssertFalse(try item(.close, in: menu).isHidden)
  }

  /// Catches an applet item that is live while a sheet or the Settings window is key. With no main
  /// window key, the item is disabled while an app item stays live.
  func testAppletItemsAreDisabledWhenNoMainWindowIsKey() throws {
    let menu = CommandMenu(
      registry: controller.commands, activeController: { [controller] in controller })
    made(0).canOpenTab = true
    menu.keyController = { [controller] in controller }

    XCTAssertTrue(menu.validateMenuItem(try item(.fakeNewTab, in: menu)))

    menu.keyController = { nil }

    XCTAssertFalse(menu.validateMenuItem(try item(.fakeNewTab, in: menu)))
    XCTAssertFalse(menu.validateMenuItem(try item(.close, in: menu)))
    XCTAssertTrue(menu.validateMenuItem(try item(.newWindow, in: menu)))
  }

  private func made(_ index: Int) -> FakeApplet { fixture.log.made[index] }

  // MARK: Find

  /// Catches a Find home that does not land in Edit > Find, or that disturbs the fixed edit items.
  /// The applet's Find item sits in a Find submenu below Select All, and it holds its key.
  func testAnAppletFindCommandLandsInTheEditFindSubmenu() throws {
    let menu = CommandMenu(
      registry: controller.commands, activeController: { [controller] in controller })
    menu.keyController = { [controller] in controller }
    menu.install()
    defer { NSApp.mainMenu = savedMenu }

    let edit = try XCTUnwrap(topMenu("Edit", in: menu)?.submenu)
    let find = try item(.fakeFind, in: menu)

    XCTAssertEqual(find.menu?.title, "Find")
    XCTAssertEqual(find.keyEquivalent, "f")
    XCTAssertEqual(edit.items.last?.submenu?.title, "Find")
    XCTAssertEqual(edit.items[6].title, "Select All")
  }

  /// Catches a Find submenu that stays under another applet or the launcher, with its key live.
  /// It shows only while the focused pane runs the applet type that declared it, and the item is
  /// disabled with no file to search.
  func testTheFindSubmenuFollowsTheFocusedAppletAndItsAvailability() throws {
    let menu = CommandMenu(
      registry: controller.commands, activeController: { [controller] in controller })
    menu.keyController = { [controller] in controller }
    menu.sync()

    let edit = try XCTUnwrap(topMenu("Edit", in: menu)?.submenu)
    let submenu = try XCTUnwrap(edit.items.last)

    XCTAssertFalse(submenu.isHidden)
    XCTAssertTrue(menu.validateMenuItem(try item(.fakeFind, in: menu)))

    made(0).canFind = false
    XCTAssertFalse(menu.validateMenuItem(try item(.fakeFind, in: menu)))

    controller.openLauncher(axis: .row)
    menu.sync()

    XCTAssertTrue(submenu.isHidden)
    XCTAssertTrue(edit.items[edit.items.count - 2].isHidden, "the separator hides with it")

    menu.keyController = { nil }
    XCTAssertFalse(menu.validateMenuItem(try item(.fakeFind, in: menu)))
  }

  /// Catches a Find key that reaches the applet only when a view is not editing text. The window
  /// routes the key to the menu before any view, so a focused text field does not swallow it.
  func testTheFindKeyRunsWhileATextFieldIsBeingEdited() throws {
    installed = install()
    let window = try XCTUnwrap(controller.window)
    window.orderFrontRegardless()
    defer { window.close() }

    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 22))
    window.contentView?.addSubview(field)
    XCTAssertTrue(window.makeFirstResponder(field))
    XCTAssertTrue(window.firstResponder is NSText, "the field is not being edited")

    XCTAssertTrue(window.performKeyEquivalent(with: try key("f", .command)))
    XCTAssertEqual(made(0).finds, 1)
  }

  /// Catches a Find command on a key uniterm reserves that keeps it. The item registers without the
  /// key, stays in Edit > Find, and one warning names it, as for any applet command.
  func testAFindCommandOnAReservedKeyLosesItLikeAnyOther() throws {
    let greedy = AppletCommandSet(
      typeID: "greedy", menuTitle: "Greedy",
      commands: [
        AppletCommand(name: "find", title: "Find It", key: KeyChord("v"), home: .editFind) { _ in },
        AppletCommand(name: "next", title: "Next It", key: KeyChord("x"), home: .editFind) { _ in },
      ])
    let registry = registry(extra: [greedy])
    let menu = CommandMenu(registry: registry, activeController: { nil })
    menu.refreshKeys()

    let find = try item(CommandRegistry.commandID(typeID: "greedy", name: "find"), in: menu)
    XCTAssertEqual(find.keyEquivalent, "")
    XCTAssertEqual(find.menu?.title, "Find")
    XCTAssertEqual(warnings.count, 1, "\(warnings)")
    XCTAssertTrue(warnings[0].contains("Find It"))
    XCTAssertTrue(warnings[0].contains("Next It"))
  }

  // MARK: Keys

  /// Catches an applet command that holds a key uniterm reserves. It registers without the key,
  /// keeps its menu item, and one warning names the applet, the command, and the key.
  func testAnAppletCommandOnAReservedKeyLosesItAndWarnsOnce() throws {
    let greedy = AppletCommandSet(
      typeID: "greedy", menuTitle: "Greedy",
      commands: [
        AppletCommand(name: "close", title: "Close It", key: KeyChord("w"), home: .applet) { _ in },
        AppletCommand(
          name: "palette", title: "Palette It", key: KeyChord("P", .command), home: .applet
        ) { _ in },
        AppletCommand(name: "paste", title: "Paste It", key: KeyChord("v"), home: .applet) { _ in },
        AppletCommand(name: "free", title: "Free", key: KeyChord("j"), home: .applet) { _ in },
      ])
    let registry = registry(extra: [greedy])
    let menu = CommandMenu(registry: registry, activeController: { nil })
    menu.refreshKeys()
    menu.refreshKeys()

    let close = try item(CommandRegistry.commandID(typeID: "greedy", name: "close"), in: menu)
    XCTAssertEqual(close.keyEquivalent, "")
    XCTAssertEqual(
      try item(CommandRegistry.commandID(typeID: "greedy", name: "paste"), in: menu).keyEquivalent,
      "")
    XCTAssertEqual(
      try item(CommandRegistry.commandID(typeID: "greedy", name: "free"), in: menu).keyEquivalent,
      "j")

    XCTAssertEqual(warnings.count, 1, "\(warnings)")
    XCTAssertTrue(warnings[0].contains("Greedy"))
    XCTAssertTrue(warnings[0].contains("Close It"))
    XCTAssertTrue(warnings[0].contains("\u{2318}W"))
    XCTAssertTrue(warnings[0].contains("Paste It"))
    XCTAssertTrue(warnings[0].contains("Keyboard Shortcuts"), "no next step: \(warnings[0])")
  }

  /// Catches two commands of one applet that share a key and keep it. Both lose it.
  func testTwoCommandsOfOneAppletOnOneKeyBothLoseIt() throws {
    let twins = AppletCommandSet(
      typeID: "twins", menuTitle: "Twins",
      commands: [
        AppletCommand(name: "a", title: "A", key: KeyChord("}", [.command, .shift]), home: .view) {
          _ in
        },
        AppletCommand(name: "b", title: "B", key: KeyChord("]", [.command, .shift]), home: .view) {
          _ in
        },
      ])
    let registry = registry(extra: [twins])
    let menu = CommandMenu(registry: registry, activeController: { nil })
    menu.refreshKeys()

    XCTAssertEqual(
      try item(CommandRegistry.commandID(typeID: "twins", name: "a"), in: menu).keyEquivalent, "")
    XCTAssertEqual(
      try item(CommandRegistry.commandID(typeID: "twins", name: "b"), in: menu).keyEquivalent, "")
    XCTAssertEqual(warnings.count, 1)
  }

  /// Catches a reserved set that is a static table. A uniterm item that moves onto an applet's key
  /// takes the reservation, the applet's key drops with one warning, and the old key comes back to
  /// the applet when the item moves away again.
  func testARemapOfAUnitermItemChangesWhichAppletKeysDrop() throws {
    let registry = registry()
    let menu = CommandMenu(registry: registry, activeController: { nil })
    menu.refreshKeys()

    let clear = try item(.fakeClear, in: menu)
    XCTAssertEqual(clear.keyEquivalent, "l")
    XCTAssertTrue(warnings.isEmpty)

    let palette = try item(.showCommandPalette, in: menu)
    palette.keyEquivalent = "l"
    palette.keyEquivalentModifierMask = .command
    menu.refreshKeys()

    XCTAssertEqual(clear.keyEquivalent, "")
    XCTAssertEqual(warnings.count, 1)
    XCTAssertTrue(warnings[0].contains("Clear Screen"))

    palette.keyEquivalent = "k"
    palette.keyEquivalentModifierMask = .command
    menu.refreshKeys()

    XCTAssertEqual(clear.keyEquivalent, "l", "the old default is not reserved any more")
    XCTAssertEqual(warnings.count, 1, "a pass that drops nothing is silent")
  }

  /// Catches a key dropped late that nobody hears about, and a repeat that nags. The startup drop
  /// warns. A later remap that drops a different key of the same applet warns again and names only
  /// the new key. The same remap checked again is silent.
  func testALaterDropOfAnotherKeyWarnsAgainAndARepeatDoesNot() throws {
    let registry = registry()
    let menu = CommandMenu(registry: registry, activeController: { nil })
    let palette = try item(.showCommandPalette, in: menu)
    let history = try item(.toggleMessageHistory, in: menu)

    palette.keyEquivalent = "l"
    palette.keyEquivalentModifierMask = .command
    menu.refreshKeys()
    menu.refreshKeys()

    XCTAssertEqual(warnings.count, 1)
    XCTAssertTrue(warnings[0].contains("Clear Screen"))

    history.keyEquivalent = "t"
    history.keyEquivalentModifierMask = .command
    menu.refreshKeys()

    XCTAssertEqual(warnings.count, 2, "\(warnings)")
    XCTAssertTrue(warnings[1].contains("New Tab"))
    XCTAssertFalse(warnings[1].contains("Clear Screen"), "a repeated drop was named again")

    menu.refreshKeys()
    XCTAssertEqual(warnings.count, 2)
  }

  /// Catches two remaps onto one key that resolve by menu order alone. The defined rule: a remap
  /// before a default, a uniterm item before an applet's, then the earlier item in the menu bar.
  /// AppKit owns the remap flag, so the items here report one.
  func testTwoRemapsOnOneKeyResolveByTheDefinedRule() throws {
    let registry = registry()
    var remappedItems: [NSMenuItem] = []

    func make(_ id: CommandID, remapped: Bool) throws -> CommandMenuItem {
      let command = try XCTUnwrap(registry.command(id))
      let item = CommandMenuItem(command)
      if remapped { remappedItems.append(item) }
      item.keyEquivalent = "j"
      item.keyEquivalentModifierMask = .command
      return item
    }

    let appletRemap = try make(.fakeClear, remapped: true)
    let unitermDefault = try make(.focusNextPane, remapped: false)
    let unitermRemapLate = try make(.toggleMessageHistory, remapped: true)
    let unitermRemapEarly = try make(.splitRight, remapped: true)

    let menu = NSMenu()
    let top = NSMenuItem()
    top.submenu = NSMenu()
    for item in [appletRemap, unitermDefault, unitermRemapEarly, unitermRemapLate] {
      top.submenu?.addItem(item)
    }
    menu.addItem(top)

    MenuKeyMatch.isRemapped = { item in remappedItems.contains { $0 === item } }
    defer { MenuKeyMatch.isRemapped = MenuKeyMatch.hasUserKeyEquivalent }

    let event = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0,
        context: nil, characters: "j", charactersIgnoringModifiers: "j", isARepeat: false,
        keyCode: 0))

    let order = MenuKeyMatch.items(for: event, in: menu)

    XCTAssertEqual(order, [unitermRemapEarly, unitermRemapLate, appletRemap, unitermDefault])
  }

  // MARK: Key route

  private func key(_ characters: String, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
    try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
        windowNumber: controller.window?.windowNumber ?? 0, context: nil, characters: characters,
        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0))
  }

  private func install() -> CommandMenu {
    let menu = CommandMenu(
      registry: controller.commands, activeController: { [controller] in controller })
    menu.keyController = { [controller] in controller }
    menu.install()
    return menu
  }

  /// Catches a reserved key whose item is disabled that falls through to the view. Cmd-W under a
  /// sheet is consumed, and nothing closes.
  func testAReservedKeyWhoseItemIsDisabledIsConsumed() throws {
    let menu = install()
    controller.openPane(.terminalShell, axis: .row)
    let window = try XCTUnwrap(controller.window)
    window.orderFrontRegardless()
    defer { window.close() }

    let sheet = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.beginSheet(sheet)

    XCTAssertFalse(menu.validateMenuItem(try item(.close, in: menu)))
    XCTAssertTrue(window.performKeyEquivalent(with: try key("w", .command)))
    XCTAssertEqual(controller.paneIDs.count, 2)

    window.endSheet(sheet)
  }

  /// Catches an applet key that the view would handle but the menu should: with an applet focused,
  /// its key runs the command. With a launcher focused, the same key is not the menu's.
  func testAnAppletKeyRunsOnlyWhileThatAppletHasFocus() throws {
    installed = install()
    made(0).canOpenTab = true
    let window = try XCTUnwrap(controller.window)

    XCTAssertTrue(window.performKeyEquivalent(with: try key("t", .command)))
    XCTAssertEqual(made(0).openedTabs, 1)

    controller.openLauncher(axis: .row)

    XCTAssertFalse(window.performKeyEquivalent(with: try key("t", .command)))
    XCTAssertEqual(made(0).openedTabs, 1)
  }

  /// Catches an applet key that is disabled and still swallowed. Unlike a reserved key, it goes on
  /// to the view.
  func testADisabledAppletKeyFallsThroughToTheView() throws {
    installed = install()
    made(0).canOpenTab = false
    let window = try XCTUnwrap(controller.window)

    XCTAssertFalse(window.performKeyEquivalent(with: try key("t", .command)))
  }

  /// Catches Redo that is live with no text being edited, which would hand Cmd-Shift-Z to a pane.
  func testRedoIsOffWhenNothingIsBeingEdited() throws {
    let window = try XCTUnwrap(controller.window)
    let item = NSMenuItem(
      title: "Redo", action: #selector(MainWindow.redoEdit(_:)), keyEquivalent: "z")

    XCTAssertFalse(window.validateMenuItem(item))
  }

  /// Catches a Cmd-W that does nothing while Settings is the key window. With no main window key,
  /// Close acts on a closable key window, and it does nothing for a sheet.
  func testCloseClosesAnotherKeyWindowButNotASheet() throws {
    let menu = CommandMenu(
      registry: controller.commands, activeController: { [controller] in controller })
    let settings = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled, .closable],
      backing: .buffered, defer: false)
    settings.isReleasedWhenClosed = false
    settings.orderFrontRegardless()

    menu.keyController = { nil }
    menu.keyWindow = { settings }

    let close = try item(.close, in: menu)
    XCTAssertTrue(menu.validateMenuItem(close))
    menu.performCommand(close)
    XCTAssertFalse(settings.isVisible)

    let window = try XCTUnwrap(controller.window)
    let sheet = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled, .closable],
      backing: .buffered, defer: false)
    window.orderFrontRegardless()
    defer { window.close() }
    window.beginSheet(sheet)
    menu.keyWindow = { sheet }

    XCTAssertFalse(menu.validateMenuItem(close))
    window.endSheet(sheet)
  }

  // MARK: Commands and the applet

  /// Catches a command that still reaches its applet after the pane closed. The action receives
  /// the applet of the pane it is aimed at when it runs and holds none, so a closed pane's applet
  /// is out of reach and the window says why nothing happened.
  func testACommandNeverReachesAnAppletAfterItsPaneClosed() throws {
    controller.openPane(.terminalShell, axis: .row)
    let pane = controller.focusedPane
    let applet = made(1)
    applet.canOpenTab = true

    controller.dispatch(.fakeBiggerText)
    XCTAssertEqual(applet.textActions, ["bigger-text"])

    controller.closePane(pane, appletEnded: true)

    let context = CommandContext(controller: controller, pane: pane)
    XCTAssertFalse(controller.commands.run(.fakeBiggerText, in: context))
    XCTAssertFalse(controller.commands.run(.fakeNewTab, in: context))
    XCTAssertEqual(applet.textActions, ["bigger-text"])
    XCTAssertEqual(applet.openedTabs, 0)
  }

  // MARK: Close

  /// Catches Cmd-W that closes a pane after the applet declined. A declined tab close keeps the
  /// tab and the pane, and only an applet with nothing to close lets the pane go.
  func testOnlyNothingToCloseClosesThePane() throws {
    controller.openPane(.terminalShell, axis: .row)
    let applet = made(1)

    applet.tabCloseOverride = .declined
    controller.dispatch(.close)
    XCTAssertEqual(controller.paneIDs.count, 2)

    applet.tabCloseOverride = .closed
    controller.dispatch(.close)
    XCTAssertEqual(controller.paneIDs.count, 2)

    applet.tabCloseOverride = .nothingToClose
    controller.dispatch(.close)
    XCTAssertEqual(controller.paneIDs.count, 1)
  }

  /// Catches the palette's close command taking another path than the menu item. Both run the
  /// registry command.
  func testTheMenuItemAndThePaletteRunTheSameCloseCommand() throws {
    let menu = CommandMenu(
      registry: controller.commands, activeController: { [controller] in controller })
    menu.keyController = { [controller] in controller }
    controller.openPane(.terminalShell, axis: .row)
    made(1).tabCloseOverride = .nothingToClose

    XCTAssertEqual(controller.commands.command(.close)?.title, "Close Tab or Pane")
    XCTAssertEqual(try item(.close, in: menu).commandID, .close)

    menu.performCommand(try item(.close, in: menu))
    XCTAssertEqual(controller.paneIDs.count, 1)
  }

  /// Catches an applet without tabs that answers anything but nothing to close, which would keep
  /// Cmd-W from ever closing its pane.
  func testAnAppletWithNoTabsAlwaysAnswersNothingToClose() async {
    let launcher = LauncherApplet(directory: nil)

    let result = await launcher.closeCurrentTab()

    XCTAssertEqual(result, .nothingToClose)
  }
}
