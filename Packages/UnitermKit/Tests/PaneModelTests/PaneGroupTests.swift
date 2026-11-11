import CoreGraphics
import XCTest

@testable import PaneModel

/// The group node kind, through the tree's public edits. Expected shapes and distances are worked
/// out by hand from the IDs each test hands out.
final class PaneGroupTests: XCTestCase {
  private let flat = PaneMetrics(
    minimumPaneSize: CGSize(width: 100, height: 50), dividerThickness: 0)

  private let wide = CGSize(width: 1200, height: 600)

  private let owner = GroupOwner(connection: 7)

  private func id(_ value: UInt64) -> NodeID { NodeID(rawValue: value) }

  /// A tree whose first pane is 1, split by its owner into 2. The group is 3 and the split is 4.
  private func ownedTree() throws -> PaneTree {
    var tree = PaneTree(metrics: flat)
    let result = try tree.split(id(1), axis: .row, in: wide, for: owner)

    XCTAssertEqual(result.pane, id(2))
    XCTAssertEqual(result.group, id(3))

    return tree
  }

  /// Catches an owner's split that does not wrap the source, puts the new pane outside the group,
  /// or makes the source a member.
  func testAnOwnersFirstSplitWrapsTheSourceAndTheNewPaneInAGroup() throws {
    let tree = try ownedTree()

    guard case .group(let group) = tree.root else { return XCTFail("the root is not a group") }

    XCTAssertEqual(group.owner, owner)
    XCTAssertEqual(group.source, id(1))
    XCTAssertEqual(group.members, [id(2)])
    XCTAssertEqual(group.content.paneIDs, [id(1), id(2)])
  }

  /// Catches a group that merges into a same-axis parent or collapses around one pane. A user
  /// splits beside the group along the group's own axis, and the member next to it closes.
  func testAGroupNeverMergesOrCollapses() throws {
    var tree = PaneTree(metrics: flat)
    _ = try tree.split(id(1), axis: .row, in: wide)
    let made = try tree.split(id(2), axis: .row, in: wide, for: owner)
    let member = made.pane
    let second = try tree.split(member, axis: .row, in: wide, for: owner).pane

    _ = try tree.close(member)

    let group = try XCTUnwrap(tree.groups.first)

    XCTAssertEqual(group.id, made.group)
    XCTAssertEqual(group.members, [second])
    XCTAssertEqual(tree.paneIDs, [id(1), id(2), second])

    guard case .split(let root) = tree.root else { return XCTFail("the root is not a split") }

    XCTAssertEqual(root.children.count, 2, "the group's content merged into the parent row")
    XCTAssertEqual(root.children[1].node.id, made.group)

    _ = try tree.close(id(2))

    let alone = try XCTUnwrap(tree.groups.first, "a group around one member collapsed")

    XCTAssertEqual(alone.content, .pane(Pane(id: second)))
  }

  /// Catches a group that outlives its last member, or whose ID is issued again. The source alone
  /// is left, so the wrapper goes and its ID retires.
  func testAGroupWithNoMemberLeftIsRemovedAndItsIDRetires() throws {
    var tree = try ownedTree()

    _ = try tree.close(id(2))

    XCTAssertTrue(tree.groups.isEmpty)
    XCTAssertEqual(tree.root, .pane(Pane(id: id(1))))
    XCTAssertTrue(tree.isRetired(id(3)))

    let next = try tree.split(id(1), axis: .row, in: wide)

    XCTAssertGreaterThan(next, id(4))
  }

  /// Catches a user split inside a group that adds a member, and an owner's later split that makes
  /// a second group instead of extending the first.
  func testAUserSplitInsideAGroupAddsNoMemberAndAnOwnersSplitExtendsIt() throws {
    var tree = try ownedTree()

    let user = try tree.split(id(2), axis: .column, in: wide)

    XCTAssertEqual(tree.groups.count, 1)
    XCTAssertEqual(tree.groups[0].members, [id(2)])
    XCTAssertTrue(tree.groups[0].content.paneIDs.contains(user))

    let extended = try tree.split(id(2), axis: .row, in: wide, for: owner)

    XCTAssertEqual(extended.group, id(3))
    XCTAssertEqual(tree.groups.count, 1)
    XCTAssertEqual(tree.groups[0].members, [id(2), extended.pane])
  }

  /// Catches another controller that extends a group it does not own, and a nested group that
  /// takes members from its parent. The second owner splits a member of the first owner's group,
  /// so a nested group wraps that member with the member as its source.
  func testAnotherOwnerGetsANestedGroupAndTheParentKeepsItsMembers() throws {
    var tree = try ownedTree()
    let other = GroupOwner(connection: 8)

    let nested = try tree.split(id(2), axis: .column, in: wide, for: other)

    XCTAssertNotEqual(nested.group, id(3))

    let groups = tree.groups

    XCTAssertEqual(groups.map(\.id), [id(3), nested.group])
    XCTAssertEqual(groups[0].members, [id(2)])
    XCTAssertEqual(groups[1].owner, other)
    XCTAssertEqual(groups[1].source, id(2))
    XCTAssertEqual(groups[1].members, [nested.pane])
    XCTAssertEqual(tree.enclosingGroups(of: nested.pane).map(\.id), [id(3), nested.group])
  }

  /// Catches a release that drops the group or its panes, or leaves the owner in place. A group
  /// of another owner keeps its owner.
  func testReleasingAnOwnerKeepsItsGroupsWithNoOwner() throws {
    var tree = try ownedTree()
    let other = GroupOwner(connection: 8)
    let nested = try tree.split(id(2), axis: .column, in: wide, for: other)

    let released = tree.releaseOwner(owner)

    XCTAssertEqual(released, [id(2)])
    XCTAssertEqual(tree.groups.map(\.owner), [nil, other])
    XCTAssertEqual(tree.paneIDs.count, 3)
    XCTAssertTrue(tree.contains(nested.pane))
  }

  /// Catches a pane alone in a group that cannot come back where it was. The group sits beside
  /// pane 1, and the pane's placement names pane 1, so undo puts it beside pane 1 outside any
  /// group.
  func testAPaneAloneInAGroupIsPlacedWhereItsGroupSat() throws {
    var tree = PaneTree(metrics: flat)
    _ = try tree.split(id(1), axis: .row, in: wide)
    let made = try tree.split(id(2), axis: .row, in: wide, for: owner)

    _ = try tree.close(id(2))

    let placement = try XCTUnwrap(tree.placement(of: made.pane))

    XCTAssertEqual(placement.neighbor, id(1))

    _ = try tree.close(made.pane)

    XCTAssertTrue(tree.groups.isEmpty)
    XCTAssertTrue(tree.isRetired(made.group))

    let back = try tree.insert(at: placement, in: wide)

    XCTAssertEqual(tree.paneIDs, [id(1), back])
    XCTAssertTrue(tree.groups.isEmpty, "a reopened pane rejoined a group")
  }

  /// Catches a group that shows up in the layout as a gap or a divider, or that changes a pane's
  /// frame. A group's frame is its content's.
  func testAGroupTakesItsContentsFrameAndAddsNoDivider() throws {
    let tree = try ownedTree()
    let layout = tree.layout(in: wide)

    XCTAssertEqual(layout.frames[id(3)], CGRect(origin: .zero, size: wide))
    XCTAssertEqual(layout.frames[id(1)]?.width, 600)
    XCTAssertEqual(layout.frames[id(2)]?.width, 600)
    XCTAssertEqual(layout.dividers.count, 1)
  }

  /// Catches a distance that counts a group's wrapper as an edge, or one that follows screen
  /// position. Pane 1 and the group sit in a row. Inside the group, pane 2 and the member sit in a
  /// column. From pane 1, each is three edges away: to the row, to the column, to the pane. From
  /// the member, pane 2 is two edges away, through the column alone.
  func testEdgeDistanceTreatsGroupsAsTransparent() throws {
    var tree = PaneTree(metrics: flat)
    _ = try tree.split(id(1), axis: .row, in: wide)
    let made = try tree.split(id(2), axis: .column, in: wide, for: owner)

    let distances = tree.edgeDistances(from: id(1))

    XCTAssertEqual(distances[id(1)], 0)
    XCTAssertEqual(distances[id(2)], 3)
    XCTAssertEqual(distances[made.pane], 3)

    let fromMember = tree.edgeDistances(from: made.pane)

    XCTAssertEqual(fromMember[id(2)], 2)
    XCTAssertEqual(fromMember[id(1)], 3)
    XCTAssertEqual(tree.edgeDistances(from: id(99)), [:])
  }

  /// Catches a restored group that keeps an owner or a member outside its content.
  func testARestoredGroupDropsMembersItDoesNotHold() throws {
    let content: Node = .split(
      Split(
        id: id(4), axis: .row,
        children: [
          Child(node: .pane(Pane(id: id(1))), weight: 0.5),
          Child(node: .pane(Pane(id: id(2))), weight: 0.5),
        ]))
    let root: Node = .group(
      Group(id: id(3), owner: nil, source: id(1), members: [id(2), id(9)], content: content))

    let tree = try PaneTree(restoring: root, highWaterMark: 9, metrics: flat)

    XCTAssertEqual(tree.groups.first?.members, [id(2)])
    XCTAssertNil(tree.groups.first?.owner)

    let empty: Node = .group(
      Group(id: id(3), owner: nil, source: nil, members: [id(9)], content: content))

    XCTAssertTrue(try PaneTree(restoring: empty, highWaterMark: 9, metrics: flat).groups.isEmpty)
  }
}
