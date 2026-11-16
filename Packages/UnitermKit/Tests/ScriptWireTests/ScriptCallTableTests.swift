import XCTest

@testable import ScriptWire

/// The table that says which Janet function is which wire call, and which power each needs. The
/// app's call boundary and the script lint both read it.
final class ScriptCallTableTests: XCTestCase {
  /// Catches a call whose name or power is changed in one place. The expected values are written
  /// out by wire code, apart from the table, so a row edited alone fails here.
  func testEveryWireCallHasItsJanetNameAndPower() {
    let expected: [UInt16: (name: String, power: ScriptCallPower?)] = [
      1: ("post-status", nil),
      2: ("list-windows", .paneControl),
      3: ("list-panes", .paneControl),
      4: ("open-pane", .paneControl),
      5: ("open-tab", .paneControl),
      6: ("send", .paneControl),
      7: ("send-command", .paneControl),
      8: ("request-layout", .paneControl),
      9: ("read-clipboard", .clipboardRead),
      10: ("write-clipboard", .clipboardWrite),
    ]
    let samples = ScriptCodecTests.calls + [.postStatus(level: .info, text: "")]
    var seen: Set<UInt16> = []

    for call in samples {
      let row = expected[call.code]

      XCTAssertEqual(call.kind.janetName, row?.name, "\(call)")
      XCTAssertEqual(call.kind.power, row?.power, "\(call)")

      seen.insert(call.code)
    }

    XCTAssertEqual(seen, Set(expected.keys))
    XCTAssertEqual(ScriptCallKind.allCases.count, expected.count)
  }

  /// Catches a name that finds the wrong call, or one that finds a call it should not.
  func testANameFindsItsCallAndAnUnknownNameFindsNone() {
    for kind in ScriptCallKind.allCases {
      XCTAssertEqual(ScriptCallKind.named(kind.janetName), kind)
    }

    XCTAssertNil(ScriptCallKind.named("api-version"))
    XCTAssertNil(ScriptCallKind.named("uniterm/send"))
  }
}
