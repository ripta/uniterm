import AppKit
import AppletCatalog
import AppletKit
import XCTest

@testable import WindowKit

/// The titles the image viewer shares with the terminal and the map. A user's App Shortcuts remap
/// matches a menu item by its title, so a shared title is how one remap covers several applets.
@MainActor
final class SharedTitleTests: XCTestCase {
  private func items(in menu: NSMenu) -> [NSMenuItem] {
    menu.items.flatMap { item in [item] + (item.submenu.map { items(in: $0) } ?? []) }
  }

  private func commandSet(_ typeID: String) throws -> AppletCommandSet {
    try XCTUnwrap(BuiltInApplets.commandSets.first { $0.typeID == typeID })
  }

  /// Catches an Actual Size title that drifts between the terminal and the image viewer, which would
  /// leave a user's remap moving only one of them. AppKit applies a remap to every menu item whose
  /// title matches, so the test applies one the same way and checks that exactly the terminal's
  /// item and the viewer's item take the key, and no other item does.
  func testOneRemapOfActualSizeMovesTheTerminalAndTheImageViewerTogether() throws {
    let registry = CommandRegistry()

    for set in BuiltInApplets.commandSets { registry.register(set) }

    let menu = CommandMenu(registry: registry, activeController: { nil })
    menu.refreshKeys()

    let remap: [String: (key: String, modifiers: NSEvent.ModifierFlags)] = [
      "Actual Size": ("j", .command)
    ]

    for item in items(in: menu.menu) {
      guard let key = remap[item.title] else { continue }

      item.keyEquivalent = key.key
      item.keyEquivalentModifierMask = key.modifiers
    }

    let moved = items(in: menu.menu).compactMap { $0 as? CommandMenuItem }
      .filter { $0.keyEquivalent == "j" && $0.keyEquivalentModifierMask == .command }
      .map(\.commandID)

    XCTAssertEqual(
      Set(moved),
      [
        CommandRegistry.commandID(typeID: "terminal", name: "actual-size"),
        CommandRegistry.commandID(typeID: "image-viewer", name: "actual-size"),
      ])
  }

  /// Catches the three zoom titles diverging from the applets they share with. Actual Size is the
  /// terminal's title. Zoom In and Zoom Out are the map's. Hidden items take no key, so sharing a
  /// title with an applet that is not focused costs nothing.
  func testTheViewerSharesItsZoomTitlesWithTheTerminalAndTheMap() throws {
    let viewer = try commandSet("image-viewer")
    let terminal = try commandSet("terminal")
    let map = try commandSet("map-viewer")

    func title(_ set: AppletCommandSet, _ name: String) -> String? {
      set.commands.first { $0.name == name }?.title
    }

    XCTAssertEqual(title(viewer, "actual-size"), title(terminal, "actual-size"))
    XCTAssertEqual(title(viewer, "zoom-in"), title(map, "zoom-in"))
    XCTAssertEqual(title(viewer, "zoom-out"), title(map, "zoom-out"))
    XCTAssertEqual(title(viewer, "actual-size"), "Actual Size")

    XCTAssertEqual(
      viewer.commands.first { $0.name == "actual-size" }?.key,
      terminal.commands.first { $0.name == "actual-size" }?.key)
  }
}
