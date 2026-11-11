import AppletKit
import Foundation
import PaneModel
import XCTest

@testable import LayoutKit

/// Schema version 3: a pane's exec declaration in its saved control, and the upgrade from version
/// 2. The expected JSON is written by hand, so the writer does not vouch for itself.
final class LayoutExecCodecTests: XCTestCase {
  private func file(control: String, version: Int = 3) -> Data {
    Data(
      """
      {"version":\(version),"windows":[{"frame":{"x":0,"y":0,"width":9,"height":9},"highWaterMark":1,
       "tree":{"kind":"pane","id":1,"control":\(control),
        "applet":{"type":"fake","version":1,"payload":null}}}]}
      """.utf8)
  }

  /// Catches a declaration that loses its argv, its directory, or its key names, and one that
  /// writes anything else: no environment value, approval, or process ever reaches the file.
  func testADeclarationSavesArgvDirectoryAndKeyNamesOnly() throws {
    let exec = try ExecDeclaration(
      arguments: ["/usr/bin/perl", "/synthetic/driver.pl", "two words"], directory: "/synthetic",
      environmentKeys: ["TOKEN", "API_KEY"])
    let tree = SavedNode.pane(
      id: NodeID(rawValue: 1), applet: fakeDescription("p1"),
      control: SavedPaneControl(access: .disconnected, driver: .none, exec: exec))

    let text = String(
      decoding: try LayoutCodec.encode(SavedLayout(windows: [window(tree: tree, mark: 1)])),
      as: UTF8.self)

    let expected =
      #""control":{"access":"disconnected","driver":"exec","exec":{"argv":["/usr/bin/perl","#
      + #""/synthetic/driver.pl","two words"],"directory":"/synthetic","#
      + #""environmentKeys":["API_KEY","TOKEN"]}}"#

    XCTAssertTrue(text.contains(expected), text)
    XCTAssertTrue(text.hasPrefix(#"{"version":3,"#))

    guard case .pane(_, _, let control) = try LayoutCodec.decode(Data(text.utf8)).windows[0].tree
    else { return XCTFail("expected a pane") }

    XCTAssertEqual(control.exec, exec)
    XCTAssertEqual(control.driver, .exec)
  }

  /// Catches a damaged declaration that names a program anyway, or a hand-added environment value
  /// that the reader takes.
  func testADamagedDeclarationReadsAsNoneAndValuesAreNeverRead() throws {
    let damaged = [
      #"{"access":"disconnected","driver":"exec","exec":{"argv":["perl"]}}"#,
      #"{"access":"disconnected","driver":"exec","exec":{"argv":[]}}"#,
      #"{"access":"disconnected","driver":"exec","exec":{"argv":[1]}}"#,
      #"{"access":"disconnected","driver":"exec","exec":{"argv":["/bin/x"],"directory":"rel"}}"#,
      #"{"access":"disconnected","driver":"exec","exec":{"argv":["/bin/x"],"environmentKeys":["1"]}}"#,
      #"{"access":"disconnected","driver":"exec","exec":"/bin/x"}"#,
    ]

    for control in damaged {
      guard
        case .pane(_, _, let saved) = try LayoutCodec.decode(file(control: control)).windows[0]
          .tree
      else { return XCTFail("expected a pane") }

      XCTAssertNil(saved.exec, control)
      XCTAssertEqual(saved.driver, .none, control)
    }

    let withValues =
      #"{"access":"disconnected","driver":"exec","exec":{"argv":["/bin/x"],"#
      + #""environmentKeys":["TOKEN"],"environment":{"TOKEN":"secret"}}}"#

    guard
      case .pane(_, _, let saved) = try LayoutCodec.decode(file(control: withValues)).windows[0]
        .tree
    else { return XCTFail("expected a pane") }

    let resaved = String(
      decoding: try LayoutCodec.encode(
        SavedLayout(windows: [
          window(
            tree: .pane(id: NodeID(rawValue: 1), applet: fakeDescription("p"), control: saved),
            mark: 1)
        ])),
      as: UTF8.self)

    XCTAssertEqual(saved.exec?.environmentKeys, ["TOKEN"])
    XCTAssertFalse(resaved.contains("secret"), resaved)
  }

  /// Catches a version 2 file that does not upgrade, or an upgrade that changes its control.
  func testAVersion2FileUpgradesUnchanged() throws {
    guard
      case .pane(_, _, let saved) = try LayoutCodec.decode(
        file(control: #"{"access":"remote-controlled","driver":"none"}"#, version: 2)
      ).windows[0].tree
    else { return XCTFail("expected a pane") }

    XCTAssertEqual(saved, SavedPaneControl(access: .remoteControlled, driver: .none))
  }
}
