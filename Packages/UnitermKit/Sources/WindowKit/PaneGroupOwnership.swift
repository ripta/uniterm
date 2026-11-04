import PaneModel

/// Who owns the groups of panes that a controller drives together. A controller that owns a group
/// can address every pane in it, so a pane that joins one comes under that controller's authority.
///
/// No controller owns a group yet, so every window answers "no". The seam exists so a routed pane
/// can be proven never to join one, against a fixture, before groups exist.
@MainActor
public protocol PaneGroupOwnership: AnyObject {
  /// True when a controller owns a group that holds the pane.
  func controllerOwnsGroup(containing pane: NodeID) -> Bool

  /// An ordinary split made `created` beside `anchor`. A group the anchor belongs to may take the
  /// new pane. A routed split never calls this.
  func paneSplit(_ created: NodeID, from anchor: NodeID)
}

/// The answer until controllers own groups.
@MainActor
final class NoPaneGroups: PaneGroupOwnership {
  func controllerOwnsGroup(containing pane: NodeID) -> Bool { false }

  func paneSplit(_ created: NodeID, from anchor: NodeID) {}
}
