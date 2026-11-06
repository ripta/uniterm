import AppKit
import AppletKit
import LayoutKit
import PaneModel

/// One window of a saved layout, ready to become a window controller.
///
/// A window controller built from it restores each pane's applet from its saved description. A
/// description that cannot be restored becomes a placeholder pane that keeps the saved bytes.
public struct RestoredWindow: Sendable {
  let saved: SavedWindow
}

/// The panes of a restored window: the tree, one applet per pane, and the focus.
struct RestoredPanes {
  let tree: PaneTree
  let applets: [NodeID: any Applet]
  let focus: NodeID

  /// How many panes show a placeholder because their description could not be restored.
  let placeholders: Int
}

@MainActor
enum PaneRestoration {
  /// Builds the tree and the applets. A description that the restorer refuses becomes a
  /// placeholder. Nothing is started.
  ///
  /// The window starts these applets with the restore origin. A pane reopened by undo goes through
  /// `applet(for:restorer:)` alone and starts with the user origin.
  static func restore(
    _ window: RestoredWindow, restorer: AppletRestorer, metrics: PaneMetrics = .standard
  ) throws -> RestoredPanes {
    var applets: [NodeID: any Applet] = [:]
    var placeholders = 0

    let root = node(
      from: window.saved.tree, restorer: restorer, applets: &applets, placeholders: &placeholders)

    let tree = try PaneTree(
      restoring: root, highWaterMark: window.saved.highWaterMark, metrics: metrics)

    let focus = window.saved.focusedPane ?? tree.paneIDs[0]
    return RestoredPanes(tree: tree, applets: applets, focus: focus, placeholders: placeholders)
  }

  /// The applet for a description. The launcher lives in WindowKit, and the app's restorer does
  /// not know its type, so the window restores it first. A description the restorer refuses becomes a placeholder that keeps
  /// its bytes.
  static func applet(
    for description: AppletDescription, restorer: AppletRestorer
  ) -> (applet: any Applet, isPlaceholder: Bool) {
    do {
      if description.type == LauncherApplet.identifier {
        return (try LauncherApplet(restoring: description), false)
      }

      return (try restorer(description), false)
    } catch {
      return (PlaceholderApplet(keeping: description, reason: reason(for: error)), true)
    }
  }

  private static func node(
    from saved: SavedNode, restorer: AppletRestorer, applets: inout [NodeID: any Applet],
    placeholders: inout Int
  ) -> Node {
    switch saved {
    case .pane(let id, let description):
      let restored = applet(for: description, restorer: restorer)
      applets[id] = restored.applet

      if restored.isPlaceholder {
        placeholders += 1
      }

      return .pane(Pane(id: id))

    case .split(let id, let axis, let children):
      let nodes = children.map {
        Child(
          node: node(
            from: $0.node, restorer: restorer, applets: &applets, placeholders: &placeholders),
          weight: $0.weight)
      }

      return .split(Split(id: id, axis: axis, children: nodes))
    }
  }

  private static func reason(for error: any Error) -> String {
    switch error as? AppletRestoreError {
    case .newerVersion?:
      return "It was saved by a newer version of uniterm. It is kept as it was."

    case .wrongType?, .unsupported?:
      return "This version of uniterm does not know how to open it. It is kept as it was."

    case .corrupt?:
      return "Its saved state is damaged. It is kept as it was."

    case nil:
      return "\(error). It is kept as it was."
    }
  }
}
