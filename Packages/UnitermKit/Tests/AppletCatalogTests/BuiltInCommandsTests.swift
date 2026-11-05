import AppletCatalog
import AppletKit
import XCTest

@testable import WindowKit

/// The commands of every applet the app ships, checked against the keys uniterm reserves.
@MainActor
final class BuiltInCommandsTests: XCTestCase {
  /// Catches a built-in applet that takes Cmd-O from the window's File > Open, whether it asks for
  /// the key outright or loses it to the reservation and still lists it. It also catches the
  /// terminal gaining an Open of its own, since it has no source to replace. A viewer added to the
  /// catalog later is covered without a new test.
  func testNoBuiltInAppletCommandClaimsCommandO() {
    let registry = CommandRegistry()

    for set in BuiltInApplets.commandSets {
      registry.register(set)
    }

    _ = CommandMenu(registry: registry, activeController: { nil })
    let commandO = KeyChord("o")

    XCTAssertFalse(BuiltInApplets.commandSets.isEmpty)

    for set in BuiltInApplets.commandSets {
      XCTAssertFalse(set.commands.contains { $0.key == commandO }, set.typeID)
    }

    XCTAssertFalse(registry.appletKeys.values.contains(commandO))

    let terminal = BuiltInApplets.commandSets.first { $0.typeID == "terminal" }
    XCTAssertFalse(terminal?.commands.contains { $0.name == AppletCommand.openSourceName } ?? true)

    let viewer = BuiltInApplets.commandSets.first { $0.typeID == "data-viewer" }
    let open = viewer?.commands.first { $0.name == AppletCommand.openSourceName }
    XCTAssertNotNil(open)
    XCTAssertNil(open?.key)
  }

  /// Catches a data viewer find key that uniterm reserves, whether a window command, a fixed Edit
  /// key, or one a later catalog entry takes. Every find key survives the reservation pass with no
  /// warning, the commands sit in Edit > Find, and Focus Filter asks for no key.
  func testTheDataViewerFindCommandsHoldTheirKeysInEditFind() throws {
    var warnings: [String] = []
    let registry = CommandRegistry(app: AppCommandHooks(warn: { warnings.append($0) }))

    for set in BuiltInApplets.commandSets {
      registry.register(set)
    }

    let menu = CommandMenu(registry: registry, activeController: { nil })
    menu.refreshKeys()

    let viewer = try XCTUnwrap(BuiltInApplets.commandSets.first { $0.typeID == "data-viewer" })
    let find = viewer.commands.filter { $0.home == .editFind }

    XCTAssertEqual(
      find.map(\.name), ["find", "find-next", "find-previous", "focus-filter"])
    XCTAssertEqual(
      find.map(\.key), [KeyChord("f"), KeyChord("g"), KeyChord("g", [.command, .shift]), nil])

    for command in find where command.key != nil {
      let id = CommandRegistry.commandID(typeID: "data-viewer", name: command.name)
      XCTAssertEqual(registry.appletKeys[id], command.key, command.title)
    }

    XCTAssertTrue(warnings.isEmpty, "\(warnings)")
  }

  /// Catches a map style command that gains a key, lands outside the View menu, or loses its
  /// name. The three commands are the registry's contract with the menu and the palette. Their
  /// keys survive the reservation pass because they ask for none.
  func testTheMapStyleCommandsSitInTheViewMenuWithNoKeys() throws {
    var warnings: [String] = []
    let registry = CommandRegistry(app: AppCommandHooks(warn: { warnings.append($0) }))

    for set in BuiltInApplets.commandSets {
      registry.register(set)
    }

    let menu = CommandMenu(registry: registry, activeController: { nil })
    menu.refreshKeys()

    let map = try XCTUnwrap(BuiltInApplets.commandSets.first { $0.typeID == "map-viewer" })

    XCTAssertEqual(map.commands.map(\.name), ["style-standard", "style-satellite", "style-hybrid"])
    XCTAssertEqual(
      map.commands.map(\.title), ["Standard Map", "Satellite Map", "Hybrid Map"])

    for command in map.commands {
      XCTAssertNil(command.key, command.title)
      XCTAssertEqual(command.home, .view, command.title)

      let id = CommandRegistry.commandID(typeID: "map-viewer", name: command.name)
      XCTAssertNil(registry.appletKeys[id], command.title)
    }

    XCTAssertTrue(warnings.isEmpty, "\(warnings)")
  }
}
