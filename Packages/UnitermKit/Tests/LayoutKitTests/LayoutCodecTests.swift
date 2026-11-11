import AppletKit
import Foundation
import PaneModel
import XCTest

@testable import LayoutKit

final class LayoutCodecTests: XCTestCase {
  private func encoded(_ layout: SavedLayout) throws -> String {
    String(decoding: try LayoutCodec.encode(layout), as: UTF8.self)
  }

  /// Catches a tree that loses a weight, an axis, an ID, the focus, or the mark in a round trip.
  /// The expected JSON is written by hand, so the writer does not vouch for itself.
  func testTheFileHoldsTheLayoutAsDocumented() throws {
    let tree = split(
      3, .row, [(pane(1), 0.25), (split(4, .column, [(pane(2), 0.5), (pane(5), 0.5)]), 0.75)])

    let saved = SavedLayout(windows: [window(tree: tree, focus: 5, mark: 9)])
    let text = try encoded(saved)

    let expected =
      #"{"version":2,"windows":[{"frame":{"x":100.0,"y":200.0,"width":900.0,"height":600.0},"#
      + #""screen":{"x":0.0,"y":0.0,"width":1440.0,"height":900.0},"focusedPane":5,"highWaterMark":9,"#
      + #""tree":{"kind":"split","id":3,"axis":"row","children":["#
      + #"{"weight":0.25,"node":{"kind":"pane","id":1,"applet":{"type":"fake","version":1,"payload":"p1"}}},"#
      + #"{"weight":0.75,"node":{"kind":"split","id":4,"axis":"column","children":["#
      + #"{"weight":0.5,"node":{"kind":"pane","id":2,"applet":{"type":"fake","version":1,"payload":"p2"}}},"#
      + #"{"weight":0.5,"node":{"kind":"pane","id":5,"applet":{"type":"fake","version":1,"payload":"p5"}}}]}}]}}]}"#

    XCTAssertEqual(text, expected)

    let decoded = try LayoutCodec.decode(Data(text.utf8))
    XCTAssertEqual(decoded.windows[0].frame, saved.windows[0].frame)
    XCTAssertEqual(decoded.windows[0].focusedPane, NodeID(rawValue: 5))
    XCTAssertEqual(decoded.windows[0].highWaterMark, 9)
    XCTAssertEqual(decoded.windows[0].tree.paneIDs.map(\.rawValue), [1, 2, 5])

    guard case .split(_, .row, let children) = decoded.windows[0].tree else {
      return XCTFail("the root should be a row split")
    }

    XCTAssertEqual(children.map(\.weight), [0.25, 0.75])
  }

  /// A mark below the largest ID in the file is raised to it, so a hand-edited or truncated mark
  /// can never let an ID in the tree be issued again.
  func testTheMarkNeverFallsBelowTheLargestID() throws {
    let text = #"""
      {"version":1,"windows":[{"frame":{"x":0,"y":0,"width":9,"height":9},"highWaterMark":2,
       "tree":{"kind":"pane","id":7,"applet":{"type":"fake","version":1,"payload":null}}}]}
      """#

    XCTAssertEqual(try LayoutCodec.decode(Data(text.utf8)).windows[0].highWaterMark, 7)
  }

  func testZeroWindowsDecodeToAnEmptyLayout() throws {
    let layout = try LayoutCodec.decode(Data(#"{"version":1,"windows":[]}"#.utf8))

    XCTAssertTrue(layout.windows.isEmpty)
  }

  // MARK: Version

  func testAVersionNewerThanThisBuildIsRefused() {
    let newer = LayoutCodec.currentVersion + 1
    let data = Data(#"{"version":\#(newer),"windows":[]}"#.utf8)

    XCTAssertThrowsError(try LayoutCodec.decode(data)) {
      XCTAssertEqual(
        $0 as? LayoutReadError,
        .newerSchema(found: newer, supported: LayoutCodec.currentVersion))
    }
  }

  func testAMissingOrNonIntegerVersionIsUnreadable() {
    for text in [#"{"windows":[]}"#, #"{"version":"1","windows":[]}"#, #"{"version":1.5}"#, "[]"] {
      XCTAssertThrowsError(try LayoutCodec.decode(Data(text.utf8)), text) {
        guard case .unreadable? = $0 as? LayoutReadError else {
          return XCTFail("\(text) should be unreadable, got \($0)")
        }
      }
    }
  }

  func testAnOlderVersionWithNoUpgradeStepIsRefused() {
    XCTAssertThrowsError(try LayoutCodec.decode(Data(#"{"version":0,"windows":[]}"#.utf8))) {
      XCTAssertEqual($0 as? LayoutReadError, .olderSchema(found: 0))
    }
  }

  func testGarbageIsUnreadable() {
    for text in ["", "not json", "{\"version\":1,", "{\"version\":1,\"windows\":[{}]}"] {
      XCTAssertThrowsError(try LayoutCodec.decode(Data(text.utf8)), text)
    }
  }

  /// Catches steps that run out of order, run twice, or skip a version.
  func testUpgradesRunOneVersionAtATimeInOrder() throws {
    let log = StepLog()

    let migrations = LayoutMigrations(steps: [
      1: { data in
        log.append("1")
        return Data(String(decoding: data, as: UTF8.self).utf8 + Data("a".utf8))
      },
      2: { data in
        log.append("2")
        return Data(String(decoding: data, as: UTF8.self).utf8 + Data("b".utf8))
      },
    ])

    let result = try migrations.upgrade(Data("x".utf8), from: 1, to: 3)

    XCTAssertEqual(log.entries, ["1", "2"])
    XCTAssertEqual(String(decoding: result, as: UTF8.self), "xab")
  }

  func testAGapInTheStepsIsRefused() {
    let migrations = LayoutMigrations(steps: [2: { $0 }])

    XCTAssertThrowsError(try migrations.upgrade(Data("x".utf8), from: 1, to: 3)) {
      XCTAssertEqual($0 as? LayoutReadError, .olderSchema(found: 1))
    }
  }

  // MARK: Structure

  func testARepeatedIDWithinAWindowIsUnreadable() {
    let tree = split(1, .row, [(pane(2), 0.5), (pane(2), 0.5)])

    XCTAssertThrowsError(
      try LayoutCodec.decode(try LayoutCodec.encode(SavedLayout(windows: [window(tree: tree)]))))
  }

  /// Two windows are separate trees, so the same ID in each is not a collision.
  func testTheSameIDInTwoWindowsIsFine() throws {
    let data = try LayoutCodec.encode(
      SavedLayout(windows: [window(tree: pane(1)), window(tree: pane(1))]))

    XCTAssertEqual(try LayoutCodec.decode(data).windows.count, 2)
  }

  func testASplitWithOneChildIsUnreadable() {
    let tree = split(1, .row, [(pane(2), 1)])

    XCTAssertThrowsError(
      try LayoutCodec.decode(try LayoutCodec.encode(SavedLayout(windows: [window(tree: tree)]))))
  }

  func testAFocusOutsideTheTreeIsDropped() throws {
    let data = try LayoutCodec.encode(SavedLayout(windows: [window(tree: pane(1), focus: 99)]))

    XCTAssertNil(try LayoutCodec.decode(data).windows[0].focusedPane)
  }

  // MARK: Bad numbers

  /// Catches one bad weight costing the whole layout. A NaN, a zero, and a negative weight are
  /// written as equal shares, so the next launch still reads the file.
  func testABadWeightIsWrittenAsAnEqualShare() throws {
    for bad in [Double.nan, 0, -1, .infinity] {
      let tree = split(1, .row, [(pane(2), bad), (pane(3), 0.9), (pane(4), 0.1)])
      let data = try LayoutCodec.encode(SavedLayout(windows: [window(tree: tree)]))
      let decoded = try LayoutCodec.decode(data)

      guard case .split(_, _, let children) = decoded.windows[0].tree else {
        return XCTFail("expected a split")
      }

      XCTAssertEqual(children.map(\.weight)[0], 1.0 / 3, accuracy: 1e-12, "\(bad)")
      XCTAssertEqual(children.count, 3)
    }
  }

  func testAnUnusableFrameIsWrittenAsADefaultOne() throws {
    let bad = window(tree: pane(1), frame: CGRect(x: CGFloat.nan, y: 0, width: 0, height: 10))
    let decoded = try LayoutCodec.decode(try LayoutCodec.encode(SavedLayout(windows: [bad])))

    XCTAssertEqual(decoded.windows[0].frame.size, CGSize(width: 960, height: 640))
  }

  /// Catches a hand-edited mark that makes the allocator overflow on the next ID. The mark is
  /// lowered to the largest the codec allows. An ID above it makes the file unreadable.
  func testAnImplausibleMarkIsLoweredAndAnImplausibleIDIsRefused() throws {
    let text = #"""
      {"version":1,"windows":[{"frame":{"x":0,"y":0,"width":9,"height":9},
       "highWaterMark":18446744073709551615,
       "tree":{"kind":"pane","id":7,"applet":{"type":"fake","version":1,"payload":null}}}]}
      """#

    XCTAssertEqual(
      try LayoutCodec.decode(Data(text.utf8)).windows[0].highWaterMark, LayoutCodec.maximumNodeID)

    let huge = text.replacingOccurrences(of: "\"id\":7", with: "\"id\":18446744073709551615")

    XCTAssertThrowsError(try LayoutCodec.decode(Data(huge.utf8)))
  }

  // MARK: Descriptions

  private func file(applet: String) -> Data {
    Data(
      """
      {"version":1,"windows":[{"frame":{"x":0,"y":0,"width":9,"height":9},"highWaterMark":1,
       "tree":{"kind":"pane","id":1,"applet":\(applet)}}]}
      """.utf8)
  }

  private func appletBytes(in data: Data) throws -> Data {
    let layout = try LayoutCodec.decode(data)

    guard case .pane(_, let applet, _) = layout.windows[0].tree else {
      throw LayoutReadError.unreadable("the test tree is not a pane")
    }

    return try XCTUnwrap(applet.verbatim, "the description lost its file bytes")
  }

  /// A description this build cannot read still comes back as the same bytes. The cases are an
  /// unknown type with a number a double rounds, a shape with no payload, and a non-object.
  func testUnreadableDescriptionsKeepTheirBytesAndWriteThemBack() throws {
    let cases = [
      #"{ "payload":{"n":12345678901234567890,"z":[1, 2]},  "type":"future", "version":7 }"#,
      #"{"type":"terminal","version":1}"#,
      #""just a string""#,
      "[1,2,3]",
      "null",
    ]

    for applet in cases {
      let data = file(applet: applet)
      let layout = try LayoutCodec.decode(data)

      XCTAssertEqual(
        String(decoding: try appletBytes(in: data), as: UTF8.self), applet,
        "the description was altered on read")

      let rewritten = try LayoutCodec.encode(layout)
      let again = try LayoutCodec.decode(rewritten)

      guard case .pane(_, let before, _) = layout.windows[0].tree,
        case .pane(_, let after, _) = again.windows[0].tree
      else { return XCTFail("expected a pane") }

      XCTAssertEqual(after.verbatim, before.verbatim)
      XCTAssertTrue(
        String(decoding: rewritten, as: UTF8.self).contains(#""applet":\#(applet)}"#),
        "the description bytes were not written back as they were: \(applet)")
    }
  }

  func testAReadableDescriptionParsesAndStillKeepsItsBytes() throws {
    let data = file(applet: #"{"type":"terminal","version":1,"payload":{"mode":"shell"}}"#)

    guard case .pane(_, let applet, _) = try LayoutCodec.decode(data).windows[0].tree else {
      return XCTFail("expected a pane")
    }

    XCTAssertEqual(applet.type, "terminal")
    XCTAssertEqual(applet.version, 1)
    XCTAssertEqual(applet.payload, .object(["mode": .string("shell")]))
    XCTAssertNotNil(applet.verbatim)
  }
}

final class StepLog: @unchecked Sendable {
  private(set) var entries: [String] = []

  func append(_ entry: String) {
    entries.append(entry)
  }
}
