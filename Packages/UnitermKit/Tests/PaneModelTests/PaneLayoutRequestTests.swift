import CoreGraphics
import XCTest

@testable import PaneModel

/// A controller's layout requests, through the tree's public edits. Expected IDs, shapes, and
/// frames are worked out by hand from the order the tree hands IDs out: the group first, then each
/// split and new pane in document order.
final class PaneLayoutRequestTests: XCTestCase {
  private let flat = PaneMetrics(
    minimumPaneSize: CGSize(width: 100, height: 50), dividerThickness: 0)

  private let wide = CGSize(width: 1200, height: 600)
  private let owner = GroupOwner(connection: 7)
  private let other = GroupOwner(connection: 8)

  private func id(_ value: UInt64) -> NodeID { NodeID(rawValue: value) }

  /// A row of the source and two new panes, stacked in a column: the presentation's shape.
  private func presentation(source: NodeID) -> PaneLayoutPlan {
    .split(
      axis: .row,
      children: [
        .init(plan: .existing(source), weight: 1),
        .init(
          plan: .split(
            axis: .column,
            children: [
              .init(plan: .new(slot: 0), weight: 1), .init(plan: .new(slot: 1), weight: 1),
            ]
          ), weight: 2),
      ])
  }

  private func refusal(_ body: () throws -> Void) -> PaneLayoutError? {
    do {
      try body()
      return nil
    } catch let error as PaneLayoutError {
      return error
    } catch {
      XCTFail("the layout threw \(error)")
      return nil
    }
  }

  /// Catches a first layout that leaves the source or a new pane outside the group, makes the
  /// source a member, drops the weights, or hands out IDs in another order.
  func testAFirstLayoutWrapsTheSourceAndTheNewPanesInAnOwnedGroup() throws {
    var tree = PaneTree(metrics: flat)
    let outcome = try tree.layOut(
      presentation(source: id(1)), anchoredAt: id(1), for: owner, slots: 2, in: wide)

    XCTAssertEqual(outcome.group, id(2))
    XCTAssertEqual(outcome.created, [id(5), id(6)])
    XCTAssertEqual(outcome.panes(of: presentation(source: id(1))), [id(1), id(5), id(6)])

    guard case .group(let group) = tree.root else { return XCTFail("the root is not a group") }

    XCTAssertEqual(group.owner, owner)
    XCTAssertEqual(group.source, id(1))
    XCTAssertEqual(group.members, [id(5), id(6)])
    XCTAssertEqual(tree.paneIDs, [id(1), id(5), id(6)])

    let frames = tree.layout(in: wide).frames

    XCTAssertEqual(frames[id(1)], CGRect(x: 0, y: 0, width: 400, height: 600))
    XCTAssertEqual(frames[id(5)], CGRect(x: 400, y: 0, width: 800, height: 300))
    XCTAssertEqual(frames[id(6)], CGRect(x: 400, y: 300, width: 800, height: 300))
  }

  /// Catches a layout that imports a pane it did not create, places a pane twice, opens nothing,
  /// or leaves out its source. Each refusal changes nothing and uses no ID.
  func testAFirstLayoutPlacesOnlyItsSourceAndNewPanes() throws {
    var tree = PaneTree(metrics: flat)
    let user = try tree.split(id(1), axis: .row, in: wide)
    let before = tree

    let first = "a first layout places the pane it starts from once, and no other open pane"
    let plans: [(PaneLayoutPlan, Int, String)] = [
      (
        .split(
          axis: .row,
          children: [
            .init(plan: .existing(id(1)), weight: 1), .init(plan: .existing(user), weight: 1),
          ]),
        0, first
      ),
      (
        .split(
          axis: .row,
          children: [
            .init(plan: .existing(id(1)), weight: 1), .init(plan: .existing(id(1)), weight: 1),
          ]),
        0, "the layout places a pane more than once"
      ),
      (
        .split(
          axis: .row,
          children: [.init(plan: .new(slot: 0), weight: 1), .init(plan: .new(slot: 1), weight: 1)]),
        2, first
      ),
      (.existing(id(1)), 0, "a first layout opens at least one pane"),
    ]

    for (plan, slots, reason) in plans {
      XCTAssertEqual(
        refusal {
          _ = try tree.layOut(plan, anchoredAt: id(1), for: owner, slots: slots, in: wide)
        },
        .refused(reason), "\(plan)")
      XCTAssertEqual(tree, before)
    }
  }

  /// Catches a later layout that loses a member, repeats one, or makes a second group. The
  /// owner's second request from the same source rearranges its group: the members move and keep
  /// their IDs, and a new pane joins.
  func testALaterLayoutRearrangesOnlyItsOwnMembers() throws {
    var tree = PaneTree(metrics: flat)
    let first = try tree.layOut(
      presentation(source: id(1)), anchoredAt: id(1), for: owner, slots: 2, in: wide)
    let (notes, chart) = (first.created[0], first.created[1])

    let swapped = PaneLayoutPlan.split(
      axis: .column,
      children: [
        .init(plan: .existing(chart), weight: 1), .init(plan: .existing(id(1)), weight: 1),
        .init(plan: .existing(notes), weight: 1), .init(plan: .new(slot: 0), weight: 1),
      ])

    let second = try tree.layOut(swapped, anchoredAt: id(1), for: owner, slots: 1, in: wide)

    XCTAssertEqual(second.group, first.group)
    XCTAssertEqual(tree.groups.count, 1)
    XCTAssertEqual(tree.paneIDs, [chart, id(1), notes, second.created[0]])
    XCTAssertEqual(tree.groups.first?.members, [notes, chart, second.created[0]])

    let dropped = PaneLayoutPlan.split(
      axis: .row,
      children: [
        .init(plan: .existing(id(1)), weight: 1), .init(plan: .existing(notes), weight: 1),
      ])
    // It places every pane of the group, so only the repeat can refuse it.
    let repeated = PaneLayoutPlan.split(
      axis: .row,
      children: [chart, chart, id(1), notes, second.created[0]].map {
        .init(plan: .existing($0), weight: 1)
      })
    let before = tree

    XCTAssertEqual(
      refusal { _ = try tree.layOut(dropped, anchoredAt: id(1), for: owner, slots: 0, in: wide) },
      .refused("a later layout places every pane of its group once, and no other pane"))
    XCTAssertEqual(
      refusal { _ = try tree.layOut(repeated, anchoredAt: id(1), for: owner, slots: 0, in: wide) },
      .refused("the layout places a pane more than once"))
    XCTAssertEqual(tree, before)
  }

  /// Catches a later layout that sweeps up a pane the user split off inside the group. The user's
  /// pane is no one's, so the group's layout cannot change until it is gone.
  func testALaterLayoutIsRefusedWhileTheGroupHoldsAUserPane() throws {
    var tree = PaneTree(metrics: flat)
    let first = try tree.layOut(
      presentation(source: id(1)), anchoredAt: id(1), for: owner, slots: 2, in: wide)
    let user = try tree.split(first.created[0], axis: .row, in: wide)
    let before = tree

    let plan = PaneLayoutPlan.split(
      axis: .row,
      children: [id(1), first.created[0], first.created[1], user].map {
        .init(plan: .existing($0), weight: 1)
      })

    guard
      case .refused(let reason)? = refusal({
        _ = try tree.layOut(plan, anchoredAt: id(1), for: owner, slots: 0, in: wide)
      })
    else { return XCTFail("a layout swept up the user's pane") }

    XCTAssertTrue(reason.contains("does not own"), reason)
    XCTAssertEqual(tree, before)
  }

  /// Catches a nested layout that merges into its parent group, takes the parent's members, or
  /// gives the parent's owner the new panes. Another controller acting from a member lays out
  /// beside it, and the member stays the parent's.
  func testANestedLayoutMakesANestedGroupAndTheParentKeepsOnlyItsMembers() throws {
    var tree = PaneTree(metrics: flat)
    let outer = try tree.layOut(
      presentation(source: id(1)), anchoredAt: id(1), for: owner, slots: 2, in: wide)
    let member = outer.created[0]

    let inner = try tree.layOut(
      .split(
        axis: .row,
        children: [
          .init(plan: .existing(member), weight: 1), .init(plan: .new(slot: 0), weight: 1),
        ]),
      anchoredAt: member, for: other, slots: 1, in: wide)

    let groups = tree.enclosingGroups(of: inner.created[0])

    XCTAssertEqual(groups.map(\.id), [outer.group, inner.group])
    XCTAssertEqual(groups.map(\.owner), [owner, other])
    XCTAssertEqual(groups[0].members, [member, outer.created[1]])
    XCTAssertEqual(groups[1].members, [inner.created[0]])
    XCTAssertEqual(groups[1].source, member)
  }

  /// Catches a layout that publishes with a pane below the minimum, or that uses IDs it does not
  /// publish.
  func testALayoutThatDoesNotFitChangesNothingAndUsesNoID() throws {
    var tree = PaneTree(metrics: flat)
    let crowded = PaneLayoutPlan.split(
      axis: .row,
      children: [.init(plan: .existing(id(1)), weight: 1)]
        + (0..<12).map { .init(plan: .new(slot: $0), weight: 1) })
    let before = tree

    XCTAssertEqual(
      refusal { _ = try tree.layOut(crowded, anchoredAt: id(1), for: owner, slots: 12, in: wide) },
      .noRoom)
    XCTAssertEqual(tree, before)
    XCTAssertEqual(tree.highWaterMark, 1)
  }

  /// Catches an adoption that takes a group someone owns, or that adds a member. Only a group with
  /// no owner can be given away, and it keeps the members it holds.
  func testOnlyAGroupWithNoOwnerCanBeAdoptedAndItGainsNoMember() throws {
    var tree = PaneTree(metrics: flat)
    let outcome = try tree.layOut(
      presentation(source: id(1)), anchoredAt: id(1), for: owner, slots: 2, in: wide)

    XCTAssertFalse(tree.adopt(outcome.group, by: other))

    tree.releaseOwner(owner)

    XCTAssertTrue(tree.adopt(outcome.group, by: other))
    XCTAssertEqual(tree.groups.first?.owner, other)
    XCTAssertEqual(tree.groups.first?.members, Set(outcome.created))
    XCTAssertFalse(tree.adopt(id(99), by: other))
  }
}
