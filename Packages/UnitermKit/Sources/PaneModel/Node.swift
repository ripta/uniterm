import CoreGraphics
import Foundation

/// A leaf of the tree. Each pane runs one applet, which the model does not know about.
public struct Pane: Sendable, Equatable {
  public let id: NodeID

  public init(id: NodeID) {
    self.id = id
  }
}

/// A child of a split, with its share of the split's space.
///
/// The weights of a split's children sum to 1.
public struct Child: Sendable, Equatable {
  public var node: Node
  public var weight: Double

  public init(node: Node, weight: Double) {
    self.node = node
    self.weight = weight
  }
}

/// A node with two or more children along one axis.
public struct Split: Sendable, Equatable {
  public let id: NodeID
  public let axis: Axis
  public var children: [Child]

  public init(id: NodeID, axis: Axis, children: [Child]) {
    self.id = id
    self.axis = axis
    self.children = children
  }
}

/// The controller that owns a group: a live connection, named by the ID its listener gave it. An
/// ID is never reused within a launch. A saved layout never holds one.
public struct GroupOwner: Sendable, Hashable, CustomStringConvertible {
  public let connection: UInt64

  public init(connection: UInt64) {
    self.connection = connection
  }

  public var description: String { "connection \(connection)" }
}

/// A node that marks the panes a controller created. It wraps one node, and never merges into its
/// parent or collapses, even around a single pane.
///
/// Its members are explicit. A pane joins only when its owner creates it there. A pane the user
/// splits off inside the group sits in its content but is not a member. The source is the pane
/// the owner first acted from, kept as placement metadata. It grants nothing by itself.
///
/// A group with no member left has nothing to mark, so it is removed and its ID retires.
public struct Group: Sendable, Equatable {
  public let id: NodeID
  public var owner: GroupOwner?
  public var source: NodeID?
  public var members: Set<NodeID>
  public var content: Node

  public init(
    id: NodeID, owner: GroupOwner?, source: NodeID?, members: Set<NodeID>, content: Node
  ) {
    self.id = id
    self.owner = owner
    self.source = source
    self.members = members
    self.content = content
  }
}

public indirect enum Node: Sendable, Equatable {
  case pane(Pane)
  case split(Split)
  case group(Group)

  public var id: NodeID {
    switch self {
    case .pane(let pane): return pane.id
    case .split(let split): return split.id
    case .group(let group): return group.id
    }
  }

  /// Every pane under this node, in reading order.
  public var paneIDs: [NodeID] {
    switch self {
    case .pane(let pane): return [pane.id]
    case .split(let split): return split.children.flatMap { $0.node.paneIDs }
    case .group(let group): return group.content.paneIDs
    }
  }

  /// The ID of this node and of every node under it.
  var allIDs: [NodeID] {
    switch self {
    case .pane(let pane): return [pane.id]
    case .split(let split): return [split.id] + split.children.flatMap { $0.node.allIDs }
    case .group(let group): return [group.id] + group.content.allIDs
    }
  }

  func contains(_ target: NodeID) -> Bool {
    switch self {
    case .pane(let pane):
      return pane.id == target

    case .split(let split):
      return split.id == target || split.children.contains { $0.node.contains(target) }

    case .group(let group):
      return group.id == target || group.content.contains(target)
    }
  }

  func find(_ target: NodeID) -> Node? {
    if id == target { return self }

    switch self {
    case .pane:
      return nil

    case .split(let split):
      for child in split.children {
        if let found = child.node.find(target) { return found }
      }

      return nil

    case .group(let group):
      return group.content.find(target)
    }
  }

  /// Every group under this node, outermost first.
  var groups: [Group] {
    switch self {
    case .pane: return []
    case .split(let split): return split.children.flatMap { $0.node.groups }
    case .group(let group): return [group] + group.content.groups
    }
  }

  /// True when this node is the pane `target`, or groups around that pane alone. Removing the
  /// pane removes the whole node then.
  func isSolely(_ target: NodeID) -> Bool {
    switch self {
    case .pane(let pane): return pane.id == target
    case .split: return false
    case .group(let group): return group.content.isSolely(target)
    }
  }
}

/// What a node becomes once it is normalized under a parent.
enum Normalized {
  /// The node stays one node.
  case node(Node)

  /// The node dissolves into its parent. The children carry weights that sum to 1 within the
  /// dissolved node. The parent scales them by the weight the node had.
  case spliced([Child])
}

// Merge and collapse rules belong to the node kind. A new kind brings its own rule, and the tree
// above it needs no change.

extension Pane {
  func normalized(parentAxis: Axis?) -> Normalized {
    .node(.pane(self))
  }

  func minimumSize(_ metrics: PaneMetrics) -> CGSize {
    metrics.minimumPaneSize
  }
}

extension Split {
  /// A split left with one child collapses into its parent. A split with the same axis as its
  /// parent merges into it. Each merged child's weight is scaled by the merged split's weight, so
  /// every pane keeps its share.
  ///
  /// Dividers take room that weights do not count, so a pane can still move a little. A merged
  /// child with weight c inside a split of m children and weight w shifts by c * (m - 1) * (1 - w)
  /// times the divider thickness. That is under (m - 1) thicknesses.
  func normalized(parentAxis: Axis?) -> Normalized {
    var flat: [Child] = []

    for child in children {
      switch child.node.normalized(parentAxis: axis) {
      case .node(let node):
        flat.append(Child(node: node, weight: child.weight))

      case .spliced(let inner):
        for grandchild in inner {
          flat.append(
            Child(node: grandchild.node, weight: child.weight * grandchild.weight))
        }
      }
    }

    guard flat.count > 1 else {
      return flat[0].node.normalized(parentAxis: parentAxis)
    }

    let total = flat.reduce(0) { $0 + $1.weight }
    let scaled = flat.map { Child(node: $0.node, weight: $0.weight / total) }

    if parentAxis == axis {
      return .spliced(scaled)
    }

    return .node(.split(Split(id: id, axis: axis, children: scaled)))
  }

  func minimumSize(_ metrics: PaneMetrics) -> CGSize {
    let sizes = children.map { $0.node.minimumSize(metrics) }
    let gaps = metrics.dividerThickness * CGFloat(children.count - 1)

    switch axis {
    case .row:
      return CGSize(
        width: sizes.reduce(0) { $0 + $1.width } + gaps, height: sizes.map(\.height).max() ?? 0)

    case .column:
      return CGSize(
        width: sizes.map(\.width).max() ?? 0, height: sizes.reduce(0) { $0 + $1.height } + gaps)
    }
  }
}

extension Group {
  /// The content is normalized as a root, so nothing in it merges through the group. Members that
  /// are not panes of the content are dropped. A group with no member left dissolves into its
  /// parent, and its content normalizes there as if the group had never been.
  func normalized(parentAxis: Axis?) -> Normalized {
    let content = content.normalizedRoot()
    let members = members.intersection(content.paneIDs)

    guard !members.isEmpty else { return content.normalized(parentAxis: parentAxis) }

    return .node(
      .group(Group(id: id, owner: owner, source: source, members: members, content: content)))
  }

  func minimumSize(_ metrics: PaneMetrics) -> CGSize {
    content.minimumSize(metrics)
  }
}

extension Node {
  func normalized(parentAxis: Axis?) -> Normalized {
    switch self {
    case .pane(let pane): return pane.normalized(parentAxis: parentAxis)
    case .split(let split): return split.normalized(parentAxis: parentAxis)
    case .group(let group): return group.normalized(parentAxis: parentAxis)
    }
  }

  func minimumSize(_ metrics: PaneMetrics) -> CGSize {
    switch self {
    case .pane(let pane): return pane.minimumSize(metrics)
    case .split(let split): return split.minimumSize(metrics)
    case .group(let group): return group.minimumSize(metrics)
    }
  }

  /// The root of a tree is normalized under no parent, so it never splices.
  func normalizedRoot() -> Node {
    switch normalized(parentAxis: nil) {
    case .node(let node): return node
    case .spliced: preconditionFailure("a root has no parent to splice into")
    }
  }
}
