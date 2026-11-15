import CoreGraphics
import Foundation

/// A gap between two adjacent siblings of a split. Dragging it moves space between them.
public struct Divider: Sendable, Equatable {
  public let split: NodeID
  public let axis: Axis
  public let leading: NodeID
  public let trailing: NodeID
  public let frame: CGRect
}

/// Where every node sits. Frames use a top-left origin, so y grows downward.
public struct PaneLayout: Sendable, Equatable {
  /// A frame for every node: panes, splits, and groups alike. A group's frame is its content's.
  public var frames: [NodeID: CGRect] = [:]
  public var dividers: [Divider] = []
}

/// Splits `total` among children by weight. A child never gets less than its minimum. A child
/// that would is pinned at its minimum, and the rest share what is left, again by weight. When the
/// minimums alone exceed `total`, every child gets its minimum and the layout overflows.
func allocate(total: CGFloat, weights: [Double], minimums: [CGFloat]) -> [CGFloat] {
  var pinned = Set<Int>()

  while true {
    let pinnedTotal = pinned.reduce(CGFloat(0)) { $0 + minimums[$1] }
    let remaining = total - pinnedTotal
    let freeWeight = weights.indices.filter { !pinned.contains($0) }.reduce(0.0) {
      $0 + weights[$1]
    }

    guard freeWeight > 0, remaining > 0 else {
      return minimums
    }

    var sizes = [CGFloat](repeating: 0, count: weights.count)
    var violators: [Int] = []

    for index in weights.indices {
      if pinned.contains(index) {
        sizes[index] = minimums[index]
      } else {
        sizes[index] = remaining * CGFloat(weights[index] / freeWeight)

        if sizes[index] < minimums[index] {
          violators.append(index)
        }
      }
    }

    if violators.isEmpty { return sizes }

    pinned.formUnion(violators)
  }
}

extension Split {
  func place(
    in rect: CGRect, metrics: PaneMetrics, clamped: Bool, into layout: inout PaneLayout
  ) {
    layout.frames[id] = rect

    let gap = metrics.dividerThickness
    let available = max(0, rect.length(along: axis) - gap * CGFloat(children.count - 1))
    let weights = children.map(\.weight)

    let lengths: [CGFloat]
    if clamped {
      lengths = allocate(
        total: available, weights: weights,
        minimums: children.map { $0.node.minimumSize(metrics).length(along: axis) })
    } else {
      lengths = weights.map { available * CGFloat($0) }
    }

    var offset: CGFloat = 0
    var previous: Node?

    for (index, child) in children.enumerated() {
      let childRect: CGRect
      switch axis {
      case .row:
        childRect = CGRect(
          x: rect.minX + offset, y: rect.minY, width: lengths[index], height: rect.height)

      case .column:
        childRect = CGRect(
          x: rect.minX, y: rect.minY + offset, width: rect.width, height: lengths[index])
      }

      if let previous {
        let dividerRect: CGRect
        switch axis {
        case .row:
          dividerRect = CGRect(
            x: childRect.minX - gap, y: rect.minY, width: gap, height: rect.height)

        case .column:
          dividerRect = CGRect(
            x: rect.minX, y: childRect.minY - gap, width: rect.width, height: gap)
        }

        layout.dividers.append(
          Divider(
            split: id, axis: axis, leading: previous.id, trailing: child.node.id,
            frame: dividerRect))
      }

      child.node.place(in: childRect, metrics: metrics, clamped: clamped, into: &layout)

      offset += lengths[index] + gap
      previous = child.node
    }
  }
}

extension Node {
  func place(
    in rect: CGRect, metrics: PaneMetrics, clamped: Bool, into layout: inout PaneLayout
  ) {
    switch self {
    case .pane(let pane):
      layout.frames[pane.id] = rect

    case .split(let split):
      split.place(in: rect, metrics: metrics, clamped: clamped, into: &layout)

    case .group(let group):
      layout.frames[group.id] = rect
      group.content.place(in: rect, metrics: metrics, clamped: clamped, into: &layout)
    }
  }
}
