import AppKit
import AppletKit
import PaneModel
import ScriptHost

/// A layout's new applets, built and not yet placed or started, with what the layout asked for.
/// Whoever stages one either publishes it or discards it, so no staged applet is left open.
@MainActor
final class StagedLayout {
  let request: LayoutRequest
  let anchor: NodeID
  let owner: GroupOwner

  /// One applet per slot, in slot order.
  var applets: [any Applet] = []

  var published = false

  init(request: LayoutRequest, anchor: NodeID, owner: GroupOwner) {
    self.request = request
    self.anchor = anchor
    self.owner = owner
  }

  /// Closes every applet a layout that will not publish built. Nothing it built has started.
  func discard() {
    guard !published else { return }

    for applet in applets { applet.close() }

    applets = []
  }
}

// MARK: Layout requests

extension MainWindowController {
  /// Runs one layout request from a controller, anchored at a pane of this window. Returns the
  /// pane at each leaf of the layout, in order.
  ///
  /// `authorize` throws when the controller may not lay out from the anchor now. It runs before
  /// anything is built, and again right before publication, after every directory check. A grant
  /// revoked, a pane disconnected, a driver's run ended, or the anchor closed while the checks
  /// wait leaves no partial layout: the staged applets close and the tree is as it was.
  ///
  /// An owner has at most one layout in preparation. A second one is refused as busy before
  /// anything is built.
  func requestLayout(
    _ request: LayoutRequest, anchor: NodeID, owner: GroupOwner,
    authorize: @MainActor () throws -> Void,
    directoryExists: @escaping @Sendable (String) -> Bool
  ) async throws -> [NodeID] {
    try authorize()

    guard layoutsInPreparation.insert(owner).inserted else {
      throw ScriptCallError.busy(
        "another layout from this program is still being prepared. Send this one when it is "
          + "answered.")
    }

    defer { layoutsInPreparation.remove(owner) }

    let staged = try stageLayout(request, anchor: anchor, owner: owner)

    do {
      for directory in request.panes.compactMap(\.directory) {
        guard await Self.exists(directory, by: directoryExists) else {
          throw ScriptCallError.badArgument("the directory \(directory) does not exist")
        }
      }

      try authorize()

      return try publish(staged)
    } catch {
      staged.discard()
      throw error
    }
  }

  /// Runs off the main actor, since a stat on a hung network mount does not return.
  @concurrent
  private nonisolated static func exists(
    _ path: String, by check: @Sendable (String) -> Bool
  ) async -> Bool {
    check(path)
  }

  /// Checks that the controller may place each pane the layout names that is already open: it is
  /// in this window and remote-controlled. The tree checks which group it belongs to, at staging
  /// and again at publication. `reach` says whether the controller may address a pane, and a pane
  /// it may not reach answers as one that is not open.
  func checkPlacedPanes(
    of request: LayoutRequest, reach: (NodeID) -> Bool
  ) throws(ScriptCallError) {
    for pane in request.plan.existingPanes {
      guard contains(pane: pane), reach(pane) else {
        throw .notFound("the pane is not open in that window")
      }

      guard control(of: pane).access == .remoteControlled else {
        throw .refused("The pane is disconnected. The user must enable remote control on it.")
      }
    }
  }

  // MARK: Adopting a restored group

  /// The group a pane's badge offers to give away: the innermost group that holds the pane as a
  /// member and has no owner.
  func unownedGroup(of pane: NodeID) -> PaneModel.Group? {
    paneArea.tree.enclosingGroups(of: pane).last { $0.members.contains(pane) && $0.owner == nil }
  }

  /// The live connections that may be given a group in this window: those that act for one of its
  /// panes now. A connection of another window is never offered, and neither is a driver, since an
  /// exec attachment gains no restored group.
  func adoptionCandidates() -> [GroupOwner] {
    guard let controllerAuthority else { return [] }

    return controllerAuthority.controllers(actingIn: scriptWindowID).sorted().map {
      GroupOwner(connection: $0)
    }
  }

  /// Gives a group with no owner to a live controller. Only the user does this, from pane chrome.
  /// The group's members stay as they are: each keeps its mode, so the user enables the ones the
  /// controller should drive. The controller gains the members the group holds now, and nothing
  /// a saved file listed beyond them.
  func adoptGroup(of pane: NodeID, by owner: GroupOwner) {
    guard let group = unownedGroup(of: pane), adoptionCandidates().contains(owner) else { return }

    guard paneArea.adopt(group.id, by: owner) else { return }

    refreshControlMarks()
  }
}
