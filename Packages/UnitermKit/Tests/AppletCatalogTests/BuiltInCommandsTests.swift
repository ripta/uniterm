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
}
