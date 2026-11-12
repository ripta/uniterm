import Foundation

/// The shape a controller asks its subtree to take. Each leaf is a pane that is already open, or a
/// slot for a new pane. Slots are numbered from 0 in document order, so the caller can match each
/// new pane to the applet it prepared for it.
public indirect enum PaneLayoutPlan: Sendable, Equatable {
  case existing(NodeID)
  case new(slot: Int)
  case split(axis: Axis, children: [Child])

  /// A child of a split, with its weight. Weights are relative, and the tree scales them to sum
  /// to 1.
  public struct Child: Sendable, Equatable {
    public var plan: PaneLayoutPlan
    public var weight: Double

    public init(plan: PaneLayoutPlan, weight: Double) {
      self.plan = plan
      self.weight = weight
    }
  }

  /// The leaves in document order.
  public var leaves: [PaneLayoutPlan] {
    switch self {
    case .existing, .new: return [self]
    case .split(_, let children): return children.flatMap(\.plan.leaves)
    }
  }

  /// The panes already open that the plan places, in document order.
  public var existingPanes: [NodeID] {
    leaves.compactMap {
      if case .existing(let pane) = $0 { return pane }

      return nil
    }
  }

  /// True when every split has two or more children, each with a positive finite weight. The
  /// tree refuses any other plan, since it cannot normalize a split with no child.
  public var isWellFormed: Bool {
    switch self {
    case .existing, .new:
      return true

    case .split(_, let children):
      return children.count >= 2
        && children.allSatisfy { $0.weight.isFinite && $0.weight > 0 && $0.plan.isWellFormed }
    }
  }

  /// The slots for new panes, in document order.
  public var slots: [Int] {
    leaves.compactMap {
      if case .new(let slot) = $0 { return slot }

      return nil
    }
  }
}

/// What a layout published: the group that holds it, and the ID each new pane got, by slot.
public struct PaneLayoutOutcome: Sendable, Equatable {
  public let group: NodeID
  public let created: [NodeID]

  public init(group: NodeID, created: [NodeID]) {
    self.group = group
    self.created = created
  }

  /// The pane at each leaf of `plan`, in document order.
  public func panes(of plan: PaneLayoutPlan) -> [NodeID] {
    plan.leaves.map {
      switch $0 {
      case .existing(let pane): return pane
      case .new(let slot): return created[slot]
      case .split: preconditionFailure("a leaf is never a split")
      }
    }
  }
}

/// Why the tree refused a layout. Nothing changed, and no ID was used.
public enum PaneLayoutError: Error, Equatable, CustomStringConvertible {
  /// The plan places panes the rules do not allow, or misses one it must place.
  case refused(String)

  /// A pane would end up below the minimum size, or the whole tree would not fit.
  case noRoom

  public var description: String {
    switch self {
    case .refused(let reason): return reason
    case .noRoom: return "the layout does not fit in the window"
    }
  }
}
