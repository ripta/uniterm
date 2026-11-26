import AppletKit
import XCTest

@testable import TerminalApplet

final class TerminalDescriptionTests: XCTestCase {
  /// Catches a description that does not survive a save and a load, so a restored pane would lose
  /// its directory.
  func testRoundTripKeepsEachTabsDirectory() throws {
    let original = TerminalDescription(
      mode: .shell,
      tabs: [
        .init(workingDirectory: "/Users/a/one"), .init(workingDirectory: nil),
        .init(workingDirectory: "/tmp"),
      ], selectedTab: 2)

    let wrapped = try original.appletDescription()
    XCTAssertEqual(wrapped.type, "terminal")
    XCTAssertEqual(wrapped.version, 2)

    XCTAssertEqual(try TerminalDescription.decode(wrapped), original)
  }

  /// Catches a build that cannot read the layout an older build saved. A version 1 payload has no
  /// scrollback IDs and reads as tabs with none.
  func testAVersionOnePayloadReadsWithNoScrollback() throws {
    let older = AppletDescription(
      type: "terminal", version: 1,
      payload: .object([
        "mode": .string("shell"),
        "tabs": .array([.object(["workingDirectory": .string("/tmp")])]),
        "selectedTab": .number(0),
      ]))

    let decoded = try TerminalDescription.decode(older)
    XCTAssertEqual(decoded.tabs, [.init(workingDirectory: "/tmp")])
    XCTAssertNil(decoded.tabs[0].scrollback)
  }

  /// The scrollback ID is a stored key too. A tab saved at quit names its file by it.
  func testPayloadShapeWithAScrollbackID() throws {
    let wrapped = try TerminalDescription(
      mode: .shell, tabs: [.init(workingDirectory: "/tmp", scrollback: "ID-1")]
    ).appletDescription()

    XCTAssertEqual(
      wrapped.payload,
      .object([
        "mode": .string("shell"),
        "tabs": .array([
          .object(["workingDirectory": .string("/tmp"), "scrollback": .string("ID-1")])
        ]),
        "selectedTab": .number(0),
      ]))
  }

  /// The payload keys are a stored format. A change to them must be deliberate, so the expected
  /// document is written out here.
  func testPayloadShape() throws {
    let wrapped = try TerminalDescription(
      mode: .shell, tabs: [.init(workingDirectory: "/tmp")]
    ).appletDescription()

    XCTAssertEqual(
      wrapped.payload,
      .object([
        "mode": .string("shell"),
        "tabs": .array([.object(["workingDirectory": .string("/tmp")])]),
        "selectedTab": .number(0),
      ]))
  }

  func testProgramModeKeepsItsCommandAsData() throws {
    let wrapped = try TerminalDescription(
      mode: .program, command: "./deploy.sh", tabs: [.init(workingDirectory: nil)]
    ).appletDescription()

    let decoded = try TerminalDescription.decode(wrapped)
    XCTAssertEqual(decoded.mode, .program)
    XCTAssertEqual(decoded.command, "./deploy.sh")
  }

  func testNewerVersionIsRefused() {
    let newer = AppletDescription(type: "terminal", version: 3, payload: .object([:]))

    XCTAssertThrowsError(try TerminalDescription.decode(newer)) {
      XCTAssertEqual($0 as? AppletRestoreError, .newerVersion(found: 3, supported: 2))
    }
  }

  func testOtherTypeIsRefused() {
    let other = AppletDescription(type: "editor", version: 1, payload: .object([:]))

    XCTAssertThrowsError(try TerminalDescription.decode(other)) {
      XCTAssertEqual($0 as? AppletRestoreError, .wrongType(expected: "terminal", found: "editor"))
    }
  }

  func testCorruptPayloadsAreRefused() {
    let shapes: [JSONValue] = [
      .string("nope"),
      .object(["mode": .string("shell"), "tabs": .array([]), "selectedTab": .number(0)]),
      .object([
        "mode": .string("shell"), "tabs": .array([.object([:])]), "selectedTab": .number(4),
      ]),
    ]

    for payload in shapes {
      let description = AppletDescription(type: "terminal", version: 1, payload: payload)

      XCTAssertThrowsError(try TerminalDescription.decode(description)) {
        guard case .corrupt = $0 as? AppletRestoreError else {
          return XCTFail("expected corrupt for \(payload), got \($0)")
        }
      }
    }
  }
}
