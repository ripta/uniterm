import AppletKit
import Foundation
import PaneModel
import XCTest

@testable import LayoutKit

/// Schema version 2: the group node, a pane's saved control, and the upgrade from version 1. The
/// expected JSON is written by hand, so the writer does not vouch for itself.
final class LayoutGroupCodecTests: XCTestCase {
  private func id(_ value: UInt64) -> NodeID { NodeID(rawValue: value) }

  /// Catches a group that loses its source, its members, or its node, a pane that loses its saved
  /// control, and a disconnected pane that writes a control it does not have.
  func testAGroupAndASavedControlAreWrittenAsDocumented() throws {
    let remote = SavedNode.pane(
      id: id(2), applet: fakeDescription("p2"),
      control: SavedPaneControl(access: .remoteControlled, driver: .none))
    let tree = SavedNode.group(
      id: id(3), source: id(1), members: [id(2)],
      node: split(4, .row, [(pane(1), 0.5), (remote, 0.5)]))

    let text = String(
      decoding: try LayoutCodec.encode(SavedLayout(windows: [window(tree: tree, mark: 4)])),
      as: UTF8.self)

    let expected =
      #""tree":{"kind":"group","id":3,"source":1,"members":[2],"node":{"kind":"split","id":4,"#
      + #""axis":"row","children":[{"weight":0.5,"node":{"kind":"pane","id":1,"#
      + #""applet":{"type":"fake","version":1,"payload":"p1"}}},{"weight":0.5,"node":{"#
      + #""kind":"pane","id":2,"control":{"access":"remote-controlled","driver":"none"},"#
      + #""applet":{"type":"fake","version":1,"payload":"p2"}}}]}}"#

    XCTAssertTrue(text.contains(expected), text)
    XCTAssertTrue(text.hasPrefix(#"{"version":2,"#))

    let decoded = try LayoutCodec.decode(Data(text.utf8))

    XCTAssertEqual(String(decoding: try LayoutCodec.encode(decoded), as: UTF8.self), text)

    guard case .group(let id, let source, let members, let node) = decoded.windows[0].tree else {
      return XCTFail("the root is not a group")
    }

    XCTAssertEqual(id, self.id(3))
    XCTAssertEqual(source, self.id(1))
    XCTAssertEqual(members, [self.id(2)])
    XCTAssertEqual(node.paneIDs, [self.id(1), self.id(2)])
  }

  /// Catches a version 1 file that does not upgrade, or an upgrade that rewrites an applet's bytes.
  /// The description has a number a double would round, so a re-serialized file would differ.
  func testAVersion1FileUpgradesWithEveryPaneDisconnectedAndItsBytesKept() throws {
    let applet = #"{"type":"future","version":7,"payload":{"n":12345678901234567890}}"#
    let text = #"""
      {"version":1,"windows":[{"frame":{"x":0,"y":0,"width":9,"height":9},"highWaterMark":1,
       "tree":{"kind":"pane","id":1,"applet":\#(applet)}}]}
      """#

    let layout = try LayoutCodec.decode(Data(text.utf8))

    guard case .pane(_, let description, let control) = layout.windows[0].tree else {
      return XCTFail("expected a pane")
    }

    XCTAssertEqual(control, .disconnected)
    XCTAssertEqual(String(decoding: try XCTUnwrap(description.verbatim), as: UTF8.self), applet)
  }

  /// Catches a damaged member list that adds a pane to a group. A member outside the group's own
  /// node, and a repeated one, are dropped. A member that is not an ID makes the file unreadable.
  func testMembersOutsideTheGroupAreDroppedAndBadOnesAreUnreadable() throws {
    func file(members: String) -> Data {
      Data(
        """
        {"version":2,"windows":[{"frame":{"x":0,"y":0,"width":9,"height":9},"highWaterMark":9,
         "tree":{"kind":"split","id":5,"axis":"row","children":[
          {"weight":0.5,"node":{"kind":"pane","id":1,"applet":{"type":"fake","version":1,"payload":1}}},
          {"weight":0.5,"node":{"kind":"group","id":3,"members":\(members),
           "node":{"kind":"pane","id":2,"applet":{"type":"fake","version":1,"payload":2}}}}]}}]}
        """.utf8)
    }

    let layout = try LayoutCodec.decode(file(members: "[2,1,9,2]"))

    guard case .split(_, _, let children) = layout.windows[0].tree,
      case .group(_, let source, let members, _) = children[1].node
    else { return XCTFail("expected a group beside a pane") }

    XCTAssertNil(source)
    XCTAssertEqual(members, [id(2)])

    for bad in [#"["2"]"#, "[0]", "7", "null"] {
      XCTAssertThrowsError(try LayoutCodec.decode(file(members: bad)), bad)
    }
  }

  /// Catches a saved control that grants something when it is damaged or names a mode this build
  /// does not know. Each reads as disconnected.
  func testAnUnknownOrDamagedControlReadsAsDisconnected() throws {
    for control in [
      #"{"access":"owner","driver":"none"}"#, #""remote-controlled""#, "[]",
      #"{"driver":"exec"}"#,
    ] {
      let text = """
        {"version":2,"windows":[{"frame":{"x":0,"y":0,"width":9,"height":9},"highWaterMark":1,
         "tree":{"kind":"pane","id":1,"control":\(control),
          "applet":{"type":"fake","version":1,"payload":null}}}]}
        """

      guard case .pane(_, _, let saved) = try LayoutCodec.decode(Data(text.utf8)).windows[0].tree
      else { return XCTFail("expected a pane") }

      XCTAssertEqual(saved.access, .disconnected, control)
    }
  }
}
