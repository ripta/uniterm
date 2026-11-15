import CoreGraphics
import Foundation

public enum PaneTreeError: Error, Equatable {
  case unknownPane(NodeID)

  /// The split would leave a pane smaller than the minimum. The pane named is the one that was
  /// split, or the new one when it is the one that is too small.
  case belowMinimumSize(NodeID)

  /// The two nodes are not neighbors under one split.
  case notAdjacent(NodeID, NodeID)

  /// A saved tree cannot be restored: an ID is zero or repeats.
  case invalidRestore(String)
}

/// Which side of its neighbor a pane sits on. `before` is left of it in a row and above it in a
/// column.
public enum Side: Sendable, Equatable {
  case before
  case after
}

/// Where a closed pane sat, kept by stable IDs so it survives changes to the tree.
///
/// The neighbor is the pane's previous sibling, or its next one when it was first. It can be a
/// split. The weight is the share the pane had of its parent split.
public struct PanePlacement: Sendable, Equatable {
  public let neighbor: NodeID
  public let axis: Axis
  public let side: Side
  public let weight: Double

  public init(neighbor: NodeID, axis: Axis, side: Side, weight: Double) {
    self.neighbor = neighbor
    self.axis = axis
    self.side = side
    self.weight = weight
  }
}

public enum CloseOutcome: Sendable, Equatable {
  /// The pane is gone. `focus` is the pane that took over its place.
  case closed(focus: NodeID)

  /// The pane is the only one, so nothing changed. The caller closes the window.
  case lastPane
}

/// The pane tree of one window: a normalized N-ary tree.
///
/// A split holds two or more children along one axis, each with a weight. A split left with one
/// child collapses. A child with its parent's axis merges into the parent. Behavior follows what
/// the user sees, never how the tree was built.
///
/// Nodes are addressed by ID. Nothing takes a path or a sibling index, since normalization
/// rewrites both.
public struct PaneTree: Sendable, Equatable {
  public private(set) var root: Node
  public let metrics: PaneMetrics
  private var allocator: NodeIDAllocator

  /// The largest ID ever handed out. A saved layout stores it.
  public var highWaterMark: UInt64 { allocator.highWaterMark }

  /// Makes a tree with one pane.
  public init(metrics: PaneMetrics = .standard, allocator: NodeIDAllocator = NodeIDAllocator()) {
    var allocator = allocator
    self.root = .pane(Pane(id: allocator.next()))
    self.metrics = metrics
    self.allocator = allocator
  }

  /// Makes a tree from a saved one. The allocator starts at `highWaterMark`, or at the largest ID in
  /// `root` when that is larger, so no ID that was handed out before the save is handed out again.
  /// That includes the IDs of panes that were closed and are not in `root`.
  ///
  /// The saved tree is normalized, since a file may have been edited. Throws when an ID is zero or
  /// repeats, because two nodes cannot share an identity.
  public init(
    restoring root: Node, highWaterMark: UInt64, metrics: PaneMetrics = .standard
  ) throws {
    var seen = Set<NodeID>()

    for id in root.allIDs {
      guard id.rawValue > 0 else { throw PaneTreeError.invalidRestore("a node has the ID 0") }

      guard seen.insert(id).inserted else {
        throw PaneTreeError.invalidRestore("the ID \(id) is used by two nodes")
      }
    }

    let highest = seen.map(\.rawValue).max() ?? 0

    self.root = root.normalizedRoot()
    self.metrics = metrics
    self.allocator = NodeIDAllocator(highWaterMark: max(highWaterMark, highest))
  }

  public var paneIDs: [NodeID] { root.paneIDs }

  public func contains(_ id: NodeID) -> Bool {
    root.contains(id)
  }

  /// True when the ID was handed out and its node is gone. A node's ID retires the moment the node
  /// leaves the tree, and nothing issues it again.
  public func isRetired(_ id: NodeID) -> Bool {
    id.rawValue <= allocator.highWaterMark && !root.contains(id)
  }

  /// The smallest size the whole tree can take without pushing a pane below its minimum.
  public var minimumSize: CGSize {
    root.minimumSize(metrics)
  }

  /// Where every node sits in `size`. When `size` is too small, the layout holds each pane at its
  /// minimum and overflows.
  public func layout(in size: CGSize) -> PaneLayout {
    layout(in: size, clamped: true)
  }

  private func layout(in size: CGSize, clamped: Bool, of node: Node? = nil) -> PaneLayout {
    var layout = PaneLayout()
    (node ?? root).place(
      in: CGRect(origin: .zero, size: size), metrics: metrics, clamped: clamped, into: &layout)
    return layout
  }

  // MARK: Split

  /// Splits a pane along `axis` and returns the new pane. The new pane sits after the old one, to
  /// its right or below it, and takes half of its space.
  ///
  /// The split is refused when either pane would end up below the minimum size. Nothing changes
  /// then, and no ID is used.
  ///
  /// A split inside a group puts the new pane in the group's content, but not among its members.
  /// Only an owner's split adds a member.
  @discardableResult
  public mutating func split(_ target: NodeID, axis: Axis, in size: CGSize) throws -> NodeID {
    try split(target, axis: axis, in: size, joining: nil).pane
  }

  /// Splits a pane for a controller and makes the new pane a member of that controller's group.
  /// The group is the innermost one around `target` that `owner` owns and that holds `target` as
  /// its source or a member. Without one, a new group wraps `target` alone, with `target` as its
  /// source. Returns the new pane and the group.
  ///
  /// The split is refused as `split(_:axis:in:)` refuses it. Nothing changes then, no group is
  /// made, and no ID is used.
  @discardableResult
  public mutating func split(
    _ target: NodeID, axis: Axis, in size: CGSize, for owner: GroupOwner
  ) throws -> (pane: NodeID, group: NodeID) {
    let existing = enclosingGroups(of: target).last {
      $0.owner == owner && ($0.source == target || $0.members.contains(target))
    }

    let result = try split(target, axis: axis, in: size, joining: (owner, existing?.id))

    guard let group = result.group else { preconditionFailure("an owner's split always joins") }

    return (result.pane, group)
  }

  private mutating func split(
    _ target: NodeID, axis: Axis, in size: CGSize, joining: (GroupOwner, NodeID?)?
  ) throws -> (pane: NodeID, group: NodeID?) {
    guard root.paneIDs.contains(target) else { throw PaneTreeError.unknownPane(target) }

    var allocator = self.allocator
    let newPane = allocator.next()
    var base = root
    var group: NodeID?

    if let (owner, existing) = joining {
      if let existing {
        group = existing
      } else {
        let id = allocator.next()
        let wrapper = Group(
          id: id, owner: owner, source: target, members: [], content: .pane(Pane(id: target)))

        base = base.wrapping(target, in: wrapper)
        group = id
      }
    }

    guard var inserted = base.splitting(target, axis: axis, newPane: newPane, allocator: &allocator)
    else { throw PaneTreeError.unknownPane(target) }

    // The member joins before normalizing, since a group with no member dissolves.
    if let group { inserted = inserted.addingMember(newPane, to: group) }

    let candidate = inserted.normalizedRoot()
    let ideal = layout(in: size, clamped: false, of: candidate)
    let minimum = metrics.minimumPaneSize

    for id in [target, newPane] {
      guard let frame = ideal.frames[id], frame.width >= minimum.width - Self.tolerance,
        frame.height >= minimum.height - Self.tolerance
      else { throw PaneTreeError.belowMinimumSize(id) }
    }

    // The new divider shifts every sibling, not only the two new panes. The tree must still fit,
    // or the layout would hold the others at their minimum and squeeze these two below theirs.
    let needed = candidate.minimumSize(metrics)

    guard needed.width <= size.width + Self.tolerance, needed.height <= size.height + Self.tolerance
    else { throw PaneTreeError.belowMinimumSize(target) }

    root = candidate
    self.allocator = allocator
    return (newPane, group)
  }

  /// True when `split(_:axis:in:)` would succeed.
  public func canSplit(_ target: NodeID, axis: Axis, in size: CGSize) -> Bool {
    var copy = self
    return (try? copy.split(target, axis: axis, in: size)) != nil
  }

  // MARK: Close

  /// Removes a pane. Its space goes to the siblings on either side, half to each. A pane with one
  /// neighbor gives all of it to that neighbor. A split left with one child collapses. The pane's
  /// ID is retired.
  ///
  /// A pane leaves every group it was a member of. A group left with no member is removed, and its
  /// ID is retired too.
  public mutating func close(_ target: NodeID) throws -> CloseOutcome {
    let panes = root.paneIDs

    guard panes.contains(target) else { throw PaneTreeError.unknownPane(target) }

    guard panes.count > 1 else { return .lastPane }

    var focus: NodeID?

    guard let removed = root.removing(target, focus: &focus) else {
      preconditionFailure("a tree with two panes keeps one after a close")
    }

    root = removed.normalizedRoot()

    guard let focus else { preconditionFailure("a removed pane always names the pane after it") }

    return .closed(focus: focus)
  }

  // MARK: Placement

  /// Where a pane sits now, in a form that `insert(at:in:)` can use after the tree has changed.
  /// The only pane has no place to come back to, so it answers nil.
  public func placement(of pane: NodeID) -> PanePlacement? {
    root.placement(of: pane)
  }

  /// Opens a new pane where the placement says, and returns its ID. The ID is a fresh one, never an
  /// ID that was retired.
  ///
  /// The pane goes beside the placement's neighbor on its side. When the neighbor now sits in a
  /// split of another axis, or is the root, the neighbor is wrapped in a new split along the
  /// placement's axis. When the neighbor is gone, the pane goes to the edge of the whole tree on
  /// the placement's side. The pane takes the placement's weight, and its siblings share the rest.
  /// When that leaves a pane below the minimum, an equal share is tried. When that fails too, the
  /// insert is refused. Nothing changes then, and no ID is used.
  @discardableResult
  public mutating func insert(at placement: PanePlacement, in size: CGSize) throws -> NodeID {
    let recorded = placement.weight > 0 && placement.weight < 1
    let weights: [Double?] = recorded ? [placement.weight, nil] : [nil]

    for weight in weights {
      var allocator = self.allocator
      let id = allocator.next()
      let candidate = root.inserting(id, at: placement, weight: weight, allocator: &allocator)

      guard fits(candidate, in: size) else { continue }

      root = candidate
      self.allocator = allocator
      return id
    }

    throw PaneTreeError.belowMinimumSize(placement.neighbor)
  }

  /// True when `insert(at:in:)` would succeed. It changes nothing and uses no ID.
  public func canInsert(at placement: PanePlacement, in size: CGSize) -> Bool {
    var copy = self
    return (try? copy.insert(at: placement, in: size)) != nil
  }

  /// True when every pane of `candidate` keeps its minimum at `size`, and the whole tree fits.
  private func fits(_ candidate: Node, in size: CGSize) -> Bool {
    let ideal = layout(in: size, clamped: false, of: candidate)
    let minimum = metrics.minimumPaneSize

    for id in candidate.paneIDs {
      guard let frame = ideal.frames[id], frame.width >= minimum.width - Self.tolerance,
        frame.height >= minimum.height - Self.tolerance
      else { return false }
    }

    let needed = candidate.minimumSize(metrics)
    return needed.width <= size.width + Self.tolerance
      && needed.height <= size.height + Self.tolerance
  }

  // MARK: Divider

  /// Moves a divider by `delta` points. Space moves between the two adjacent children, and no
  /// other child changes. The move stops where either child would drop below its minimum.
  /// Returns the distance the divider moved.
  @discardableResult
  public mutating func moveDivider(
    between leading: NodeID, and trailing: NodeID, by delta: CGFloat, in size: CGSize
  ) throws -> CGFloat {
    guard let split = root.split(holding: leading, then: trailing) else {
      throw PaneTreeError.notAdjacent(leading, trailing)
    }

    let current = layout(in: size)

    guard let leadingFrame = current.frames[leading], let trailingFrame = current.frames[trailing],
      let leadingNode = root.find(leading), let trailingNode = root.find(trailing)
    else { throw PaneTreeError.notAdjacent(leading, trailing) }

    let axis = split.axis
    let leadingLength = leadingFrame.length(along: axis)
    let total = leadingLength + trailingFrame.length(along: axis)
    let lower = leadingNode.minimumSize(metrics).length(along: axis)
    let upper = total - trailingNode.minimumSize(metrics).length(along: axis)

    guard lower <= upper, total > 0 else { return 0 }

    let moved = min(max(leadingLength + delta, lower), upper)

    let leadingWeight = split.children.first { $0.node.id == leading }?.weight ?? 0
    let trailingWeight = split.children.first { $0.node.id == trailing }?.weight ?? 0
    let pair = leadingWeight + trailingWeight
    let newLeading = pair * Double(moved / total)

    root = root.settingWeights(
      split: split.id, leading: (leading, newLeading), trailing: (trailing, pair - newLeading))

    return moved - leadingLength
  }

  // MARK: Focus order

  /// The pane after `id` in reading order, wrapping around.
  public func nextPane(after id: NodeID) -> NodeID? {
    let ids = paneIDs
    guard let index = ids.firstIndex(of: id) else { return nil }

    return ids[(index + 1) % ids.count]
  }

  /// The pane before `id` in reading order, wrapping around.
  public func previousPane(before id: NodeID) -> NodeID? {
    let ids = paneIDs
    guard let index = ids.firstIndex(of: id) else { return nil }

    return ids[(index + ids.count - 1) % ids.count]
  }

  /// The nearest pane in `direction` whose span overlaps the pane's own. Among equals, the one with
  /// the larger overlap wins, then the one nearer the top left.
  public func neighbor(of id: NodeID, toward direction: Direction, in size: CGSize) -> NodeID? {
    let frames = layout(in: size).frames
    guard let origin = frames[id] else { return nil }

    var best: (id: NodeID, distance: CGFloat, overlap: CGFloat, frame: CGRect)?

    for candidate in paneIDs where candidate != id {
      guard let frame = frames[candidate] else { continue }

      let distance: CGFloat
      let overlap: CGFloat

      switch direction {
      case .right:
        distance = frame.minX - origin.maxX
        overlap = Self.overlap(origin.minY, origin.maxY, frame.minY, frame.maxY)

      case .left:
        distance = origin.minX - frame.maxX
        overlap = Self.overlap(origin.minY, origin.maxY, frame.minY, frame.maxY)

      case .down:
        distance = frame.minY - origin.maxY
        overlap = Self.overlap(origin.minX, origin.maxX, frame.minX, frame.maxX)

      case .up:
        distance = origin.minY - frame.maxY
        overlap = Self.overlap(origin.minX, origin.maxX, frame.minX, frame.maxX)
      }

      guard distance >= -Self.tolerance, overlap > Self.tolerance else { continue }

      if let current = best {
        let nearer = distance < current.distance - Self.tolerance
        let sameDistance = abs(distance - current.distance) <= Self.tolerance
        let moreOverlap = overlap > current.overlap + Self.tolerance
        let sameOverlap = abs(overlap - current.overlap) <= Self.tolerance
        let nearerOrigin =
          (frame.minY, frame.minX) < (current.frame.minY, current.frame.minX)

        guard nearer || (sameDistance && (moreOverlap || (sameOverlap && nearerOrigin))) else {
          continue
        }
      }

      best = (candidate, distance, overlap, frame)
    }

    return best?.id
  }

  private static func overlap(
    _ lowA: CGFloat, _ highA: CGFloat, _ lowB: CGFloat, _ highB: CGFloat
  ) -> CGFloat {
    max(0, min(highA, highB) - max(lowA, lowB))
  }

  static let tolerance: CGFloat = 0.000_1

  // MARK: Groups

  /// Every group in the tree, outermost first.
  public var groups: [Group] { root.groups }

  /// The groups around a pane, outermost first. A pane in no group has none.
  public func enclosingGroups(of pane: NodeID) -> [Group] {
    root.groups.filter { $0.content.paneIDs.contains(pane) }
  }

  /// Takes ownership away from `owner` in every group it owns. The groups and their panes stay,
  /// with no owner, and no one can claim them again. Returns the panes that were members of them.
  @discardableResult
  public mutating func releaseOwner(_ owner: GroupOwner) -> Set<NodeID> {
    var released = Set<NodeID>()

    root = root.releasing(owner, into: &released)

    return released
  }

  /// Gives a group that has no owner to `owner`. Its members are the ones it holds now, and the
  /// group gains none. Returns false, and changes nothing, when the group is not here or still
  /// has an owner.
  @discardableResult
  public mutating func adopt(_ group: NodeID, by owner: GroupOwner) -> Bool {
    guard case .group(let found)? = root.find(group), found.owner == nil else { return false }

    root = root.updatingGroup(group) { $0.owner = owner }
    return true
  }

  // MARK: Layout requests

  /// Lays out a controller's subtree as `plan` says, with `slots` new panes, and returns the group
  /// and the new panes' IDs by slot.
  ///
  /// The subtree is the innermost group around `anchor` that `owner` owns with `anchor` as its
  /// source. A later layout rearranges that group's content: it must place every pane the content
  /// holds exactly once, and the content may hold only the group's source and members. Without
  /// such a group, this is a first layout. It places `anchor` once and no other open pane, opens
  /// at least one, and wraps them in a new group with `anchor` as its source. A group the anchor
  /// is already a member of then holds the new one nested inside it.
  ///
  /// The new panes are members of the group, and so are the members it had. The split IDs inside
  /// a rearranged group are new. A refusal changes nothing and uses no ID.
  public mutating func layOut(
    _ plan: PaneLayoutPlan, anchoredAt anchor: NodeID, for owner: GroupOwner, slots: Int,
    in size: CGSize
  ) throws -> PaneLayoutOutcome {
    guard root.paneIDs.contains(anchor) else { throw PaneTreeError.unknownPane(anchor) }

    guard plan.isWellFormed else {
      throw PaneLayoutError.refused("a split needs two or more children with positive weights")
    }

    guard plan.slots == Array(0..<slots) else {
      throw PaneLayoutError.refused("the layout's new panes are not numbered in order")
    }

    let placed = plan.existingPanes

    guard Set(placed).count == placed.count else {
      throw PaneLayoutError.refused("the layout places a pane more than once")
    }

    var allocator = self.allocator
    let base: Node
    let groupID: NodeID
    var created: [NodeID] = []

    if let group = enclosingGroups(of: anchor).last(where: {
      $0.owner == owner && $0.source == anchor
    }) {
      let content = group.content.paneIDs
      let own = group.members.union([anchor])

      guard group.content.groups.isEmpty, Set(content).isSubset(of: own) else {
        throw PaneLayoutError.refused(
          "the group holds a pane this program does not own, such as one the user split off, so "
            + "its layout cannot change")
      }

      guard Set(placed) == Set(content) else {
        throw PaneLayoutError.refused(
          "a later layout places every pane of its group once, and no other pane")
      }

      let built = plan.built(allocator: &allocator, created: &created)

      base = root.updatingGroup(group.id) {
        $0.content = built
        $0.members.formUnion(created)
      }
      groupID = group.id
    } else {
      guard placed == [anchor] else {
        throw PaneLayoutError.refused(
          "a first layout places the pane it starts from once, and no other open pane")
      }

      guard slots > 0 else {
        throw PaneLayoutError.refused("a first layout opens at least one pane")
      }

      let id = allocator.next()
      let built = plan.built(allocator: &allocator, created: &created)
      let wrapper = Group(
        id: id, owner: owner, source: anchor, members: Set(created), content: built)

      base = root.wrapping(anchor, in: wrapper)
      groupID = id
    }

    let candidate = base.normalizedRoot()

    guard fits(candidate, in: size) else { throw PaneLayoutError.noRoom }

    guard candidate.find(groupID) != nil else {
      preconditionFailure("a layout's group always keeps a member")
    }

    root = candidate
    self.allocator = allocator
    return PaneLayoutOutcome(group: groupID, created: created)
  }

  // MARK: Distance

  /// How many split edges lie between `source` and each pane, in the tree as it is now. A group is
  /// transparent: entering or leaving one costs nothing. The source is 0 from itself. A pane not in
  /// the tree has no entry, and an unknown source gives an empty map.
  public func edgeDistances(from source: NodeID) -> [NodeID: Int] {
    var paths: [NodeID: [NodeID]] = [:]

    root.collectSplitPaths(prefix: [], into: &paths)

    guard let from = paths[source] else { return [:] }

    var distances: [NodeID: Int] = [:]

    for (pane, path) in paths {
      guard pane != source else {
        distances[pane] = 0
        continue
      }

      // Two different panes always share the root split, so the common prefix is at least one.
      let common = zip(from, path).prefix { $0 == $1 }.count

      distances[pane] = from.count + path.count - 2 * (common - 1)
    }

    return distances
  }
}

// MARK: Recursive edits

extension Node {
  /// Where `target` sits, as a neighbor and a side. Returns nil when it is not a child of a split.
  /// A pane alone in a group sits where its group does.
  func placement(of target: NodeID) -> PanePlacement? {
    switch self {
    case .pane: return nil
    case .group(let group): return group.content.placement(of: target)
    case .split(let split): return split.placement(of: target)
    }
  }

  /// This node with the pane `target` replaced by `group`, which wraps it. Nothing is normalized.
  func wrapping(_ target: NodeID, in group: Group) -> Node {
    switch self {
    case .pane(let pane):
      return pane.id == target ? .group(group) : self

    case .split(var split):
      for index in split.children.indices {
        split.children[index].node = split.children[index].node.wrapping(target, in: group)
      }

      return .split(split)

    case .group(var outer):
      outer.content = outer.content.wrapping(target, in: group)
      return .group(outer)
    }
  }

  /// This node with `pane` added to the members of the group `group`. Nothing is normalized.
  func addingMember(_ pane: NodeID, to group: NodeID) -> Node {
    switch self {
    case .pane:
      return self

    case .split(var split):
      for index in split.children.indices {
        split.children[index].node = split.children[index].node.addingMember(pane, to: group)
      }

      return .split(split)

    case .group(var found):
      if found.id == group {
        found.members.insert(pane)
      } else {
        found.content = found.content.addingMember(pane, to: group)
      }

      return .group(found)
    }
  }

  /// This node with `change` applied to the group `id`. Nothing is normalized.
  func updatingGroup(_ id: NodeID, _ change: (inout Group) -> Void) -> Node {
    switch self {
    case .pane:
      return self

    case .split(var split):
      for index in split.children.indices {
        split.children[index].node = split.children[index].node.updatingGroup(id, change)
      }

      return .split(split)

    case .group(var group):
      if group.id == id {
        change(&group)
      } else {
        group.content = group.content.updatingGroup(id, change)
      }

      return .group(group)
    }
  }

  func releasing(_ owner: GroupOwner, into released: inout Set<NodeID>) -> Node {
    switch self {
    case .pane:
      return self

    case .split(var split):
      for index in split.children.indices {
        split.children[index].node = split.children[index].node.releasing(owner, into: &released)
      }

      return .split(split)

    case .group(var group):
      if group.owner == owner {
        group.owner = nil
        released.formUnion(group.members)
      }

      group.content = group.content.releasing(owner, into: &released)
      return .group(group)
    }
  }

  /// The splits above each pane, from the root down. Groups are left out of the paths.
  func collectSplitPaths(prefix: [NodeID], into paths: inout [NodeID: [NodeID]]) {
    switch self {
    case .pane(let pane):
      paths[pane.id] = prefix

    case .split(let split):
      for child in split.children {
        child.node.collectSplitPaths(prefix: prefix + [split.id], into: &paths)
      }

    case .group(let group):
      group.content.collectSplitPaths(prefix: prefix, into: &paths)
    }
  }

  /// This node with the pane `target` gone, or nil when nothing is left of it.
  func removing(_ target: NodeID, focus: inout NodeID?) -> Node? {
    switch self {
    case .pane(let pane):
      return pane.id == target ? nil : self

    case .split(let split):
      return split.removing(target, focus: &focus)

    case .group(var group):
      guard let content = group.content.removing(target, focus: &focus) else { return nil }

      group.content = content
      group.members.remove(target)
      return .group(group)
    }
  }
}

extension Split {
  func placement(of target: NodeID) -> PanePlacement? {
    let split = self

    if let index = split.children.firstIndex(where: { $0.node.isSolely(target) }) {
      let weight = split.children[index].weight

      if index > 0 {
        return PanePlacement(
          neighbor: split.children[index - 1].node.id, axis: split.axis, side: .after,
          weight: weight)
      }

      return PanePlacement(
        neighbor: split.children[index + 1].node.id, axis: split.axis, side: .before,
        weight: weight)
    }

    for child in split.children {
      if let found = child.node.placement(of: target) { return found }
    }

    return nil
  }
}

extension Node {
  /// This node with `pane` added as the placement describes. The result is a normalized root.
  func inserting(
    _ pane: NodeID, at placement: PanePlacement, weight: Double?, allocator: inout NodeIDAllocator
  ) -> Node {
    let axis = placement.axis
    let side = placement.side

    if id == placement.neighbor {
      return wrapping(pane, axis: axis, side: side, weight: weight, allocator: &allocator)
        .normalizedRoot()
    }

    if let found = inserting(
      pane, beside: placement.neighbor, axis: axis, side: side, weight: weight,
      allocator: &allocator)
    {
      return found.normalizedRoot()
    }

    if case .split(var split) = self, split.axis == axis {
      split.addChild(pane, at: side == .before ? 0 : split.children.count, weight: weight)
      let edited: Node = .split(split)
      return edited.normalizedRoot()
    }

    return wrapping(pane, axis: axis, side: side, weight: weight, allocator: &allocator)
      .normalizedRoot()
  }

  private func inserting(
    _ pane: NodeID, beside neighbor: NodeID, axis: Axis, side: Side, weight: Double?,
    allocator: inout NodeIDAllocator
  ) -> Node? {
    if case .group(var group) = self {
      if group.content.id == neighbor {
        group.content = group.content.wrapping(
          pane, axis: axis, side: side, weight: weight, allocator: &allocator)
      } else {
        guard
          let inner = group.content.inserting(
            pane, beside: neighbor, axis: axis, side: side, weight: weight, allocator: &allocator)
        else { return nil }

        group.content = inner
      }

      return .group(group)
    }

    guard case .split(var split) = self else { return nil }

    if let index = split.children.firstIndex(where: { $0.node.id == neighbor }) {
      if split.axis == axis {
        split.addChild(pane, at: side == .before ? index : index + 1, weight: weight)
      } else {
        split.children[index].node = split.children[index].node.wrapping(
          pane, axis: axis, side: side, weight: weight, allocator: &allocator)
      }

      return .split(split)
    }

    for index in split.children.indices where split.children[index].node.contains(neighbor) {
      guard
        let replaced = split.children[index].node.inserting(
          pane, beside: neighbor, axis: axis, side: side, weight: weight, allocator: &allocator)
      else { return nil }

      split.children[index].node = replaced
      return .split(split)
    }

    return nil
  }

  /// A new split along `axis` that holds this node and the new pane. An unrecorded weight gives each
  /// half.
  private func wrapping(
    _ pane: NodeID, axis: Axis, side: Side, weight: Double?, allocator: inout NodeIDAllocator
  ) -> Node {
    let share = weight ?? 0.5
    let added = Child(node: .pane(Pane(id: pane)), weight: share)
    let existing = Child(node: self, weight: 1 - share)

    return .split(
      Split(
        id: allocator.next(), axis: axis,
        children: side == .before ? [added, existing] : [existing, added]))
  }

  /// Splits the pane `target` under this node. Returns nil when the pane is not here.
  func splitting(
    _ target: NodeID, axis: Axis, newPane: NodeID, allocator: inout NodeIDAllocator
  ) -> Node? {
    switch self {
    case .pane(let pane):
      guard pane.id == target else { return nil }

      return .split(
        Split(
          id: allocator.next(), axis: axis,
          children: [
            Child(node: self, weight: 0.5), Child(node: .pane(Pane(id: newPane)), weight: 0.5),
          ]
        ))

    case .group(var group):
      guard
        let replaced = group.content.splitting(
          target, axis: axis, newPane: newPane, allocator: &allocator)
      else { return nil }

      group.content = replaced
      return .group(group)

    case .split(var split):
      guard let index = split.children.firstIndex(where: { $0.node.contains(target) }) else {
        return nil
      }

      let child = split.children[index]

      if case .pane = child.node, split.axis == axis {
        let half = child.weight / 2
        split.children[index].weight = half
        split.children.insert(
          Child(node: .pane(Pane(id: newPane)), weight: half), at: index + 1)
      } else if let replaced = child.node.splitting(
        target, axis: axis, newPane: newPane, allocator: &allocator)
      {
        split.children[index].node = replaced
      } else {
        return nil
      }

      return .split(split)
    }
  }

  /// The split that holds `leading` immediately followed by `trailing`.
  func split(holding leading: NodeID, then trailing: NodeID) -> Split? {
    if case .group(let group) = self {
      return group.content.split(holding: leading, then: trailing)
    }

    guard case .split(let split) = self else { return nil }

    let ids = split.children.map { $0.node.id }
    if let index = ids.firstIndex(of: leading), index + 1 < ids.count, ids[index + 1] == trailing {
      return split
    }

    for child in split.children {
      if let found = child.node.split(holding: leading, then: trailing) { return found }
    }

    return nil
  }

  func settingWeights(
    split target: NodeID, leading: (NodeID, Double), trailing: (NodeID, Double)
  ) -> Node {
    if case .group(var group) = self {
      group.content = group.content.settingWeights(
        split: target, leading: leading, trailing: trailing)
      return .group(group)
    }

    guard case .split(var split) = self else { return self }

    if split.id == target {
      for index in split.children.indices {
        switch split.children[index].node.id {
        case leading.0: split.children[index].weight = leading.1
        case trailing.0: split.children[index].weight = trailing.1
        default: break
        }
      }
    } else {
      for index in split.children.indices {
        split.children[index].node = split.children[index].node.settingWeights(
          split: target, leading: leading, trailing: trailing)
      }
    }

    return .split(split)
  }
}

extension PaneLayoutPlan {
  /// The plan as nodes, with fresh IDs for its splits and new panes. Each new pane's ID is
  /// appended to `created` as it is reached, so in slot order. Nothing is normalized.
  func built(allocator: inout NodeIDAllocator, created: inout [NodeID]) -> Node {
    switch self {
    case .existing(let pane):
      return .pane(Pane(id: pane))

    case .new:
      let id = allocator.next()

      created.append(id)
      return .pane(Pane(id: id))

    case .split(let axis, let children):
      let id = allocator.next()
      let nodes = children.map {
        PaneModel.Child(
          node: $0.plan.built(allocator: &allocator, created: &created), weight: $0.weight)
      }

      return .split(Split(id: id, axis: axis, children: nodes))
    }
  }
}

extension Split {
  /// Adds a pane child at `index`. The pane takes `weight`, and the other children share the rest in
  /// proportion. Without a weight, the pane takes an equal share.
  mutating func addChild(_ pane: NodeID, at index: Int, weight: Double?) {
    let share = weight ?? 1 / Double(children.count + 1)

    for position in children.indices {
      children[position].weight *= 1 - share
    }

    children.insert(Child(node: .pane(Pane(id: pane)), weight: share), at: index)
  }

  /// Removes the pane from this split or a node below it. A child that is the pane, or a group
  /// around the pane alone, goes as a whole. The result may need normalizing.
  func removing(_ target: NodeID, focus: inout NodeID?) -> Node {
    var split = self

    if let index = split.children.firstIndex(where: { $0.node.isSolely(target) }) {
      let weight = split.children[index].weight
      let previous = index > 0 ? index - 1 : nil
      let next = index + 1 < split.children.count ? index + 1 : nil

      switch (previous, next) {
      case (let previous?, let next?):
        split.children[previous].weight += weight / 2
        split.children[next].weight += weight / 2
        focus = split.children[previous].node.paneIDs.last

      case (let previous?, nil):
        split.children[previous].weight += weight
        focus = split.children[previous].node.paneIDs.last

      case (nil, let next?):
        split.children[next].weight += weight
        focus = split.children[next].node.paneIDs.first

      case (nil, nil):
        break
      }

      split.children.remove(at: index)
      return .split(split)
    }

    for index in split.children.indices where split.children[index].node.contains(target) {
      if let remaining = split.children[index].node.removing(target, focus: &focus) {
        split.children[index].node = remaining
      }
    }

    return .split(split)
  }
}
