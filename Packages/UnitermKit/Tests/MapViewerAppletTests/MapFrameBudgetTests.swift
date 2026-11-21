import Foundation
import GeoData
import XCTest

@testable import ExecDriver
@testable import MapViewerApplet
@testable import ScriptWire

/// Proves the per-layer pin cap against the exec wire as shipped. The sizes here come from text
/// the test builds byte by byte, not from the code that computes the cap.
@MainActor
final class MapFrameBudgetTests: XCTestCase {
  /// Catches a mirrored bound that drifted from the exec protocol's, which would size the cap for a
  /// wire that no longer exists.
  func testTheSizingBoundsMirrorTheExecProtocol() {
    XCTAssertEqual(CommandFrameSizing.frameBytes, ExecProtocol.maxFrameBytes)
    XCTAssertEqual(CommandFrameSizing.maxValues, ExecProtocol.maxValues)
    XCTAssertEqual(CommandFrameSizing.retainedBytes, ExecProtocol.maxRetainedBytes)
    XCTAssertEqual(CommandFrameSizing.requestIDBytes, ExecProtocol.maxRequestIDBytes)
    XCTAssertEqual(CommandPinLimits.maxLayerNameBytes, ExecProtocol.maxNameBytes)
  }

  /// JSON text for a string of `count` control bytes, every one escaped to six bytes.
  private func escapedControls(_ count: Int) -> String {
    "\"" + String(repeating: "\\u0001", count: count) + "\""
  }

  /// A worst-case command frame for `pins` pins: the longest request ID, layer name, and numbers,
  /// and every byte of every text field escaped.
  private func frame(pins: Int) -> Data {
    let number = "-1.2345678901234567e-300"
    let pin =
      "{\"id\":\(escapedControls(64)),\"coordinate\":{\"latitude\":\(number),\"longitude\":\(number)},"
      + "\"label\":\(escapedControls(128)),\"accent\":\"rosewater\",\"glyph\":\(escapedControls(64))}"
    let list = Array(repeating: pin, count: pins).joined(separator: ",")
    let text =
      "{\"type\":\"command\",\"id\":\(escapedControls(64)),\"pane\":9007199254740991,"
      + "\"applet\":\"map-viewer\",\"schema\":[2147483647,2147483647],\"name\":\"set-layer\","
      + "\"arguments\":{\"layer\":\(escapedControls(64)),\"pins\":[\(list)]}}"

    return Data(text.utf8)
  }

  /// Catches a cap that lets a full layer past the frame, and one that leaves room unused. The
  /// largest layer reads as one command through the real frame reader and decoder. One pin more
  /// is a frame the reader refuses.
  func testAFullWorstCaseLayerFitsOneFrameAndOnePinMoreDoesNot() throws {
    let cap = CommandPinLimits.maxPinsPerLayer
    let full = frame(pins: cap)

    XCTAssertLessThanOrEqual(full.count, ExecProtocol.maxFrameBytes)
    XCTAssertGreaterThan(cap, 100)

    var reader = ExecFrameReader()
    let frames = try reader.feed(Array(full) + [0x0A])

    XCTAssertEqual(frames.count, 1)

    guard
      case .paneCommand(_, _, let type, _, let name, let arguments) = try ExecWire.decode(
        try XCTUnwrap(frames.first))
    else { return XCTFail("not a pane command") }

    XCTAssertEqual(type, "map-viewer")
    XCTAssertEqual(name, "set-layer")

    guard case .object(let fields) = arguments, case .array(let pins)? = fields["pins"] else {
      return XCTFail("no pins")
    }

    XCTAssertEqual(pins.count, cap)

    let past = frame(pins: cap + 1)

    XCTAssertGreaterThan(past.count, ExecProtocol.maxFrameBytes)

    var strict = ExecFrameReader()

    XCTAssertThrowsError(try strict.feed(Array(past) + [0x0A])) {
      XCTAssertEqual($0 as? ExecWireError, .frameTooLong)
    }

    XCTAssertLessThan(
      ExecProtocol.maxFrameBytes - full.count, frame(pins: cap + 1).count - full.count,
      "the cap left room for another pin")
  }

  /// Catches the value bound being the one that is spent first. The frame binds at the cap, with
  /// room to spare in the decoded-value count.
  func testTheValueBoundHoldsAtTheCap() throws {
    let cap = CommandPinLimits.maxPinsPerLayer

    XCTAssertNoThrow(try ExecWire.checkBounds(frame(pins: cap)))
    XCTAssertLessThan(cap * 20 + 64, ExecProtocol.maxValues)
  }

  /// Catches a claim that a script can send a full layer. A script call's arguments stop at 32 KiB,
  /// and a full layer of even the shortest ordinary pins is larger. The window test owns the
  /// contract that an oversized call has no effect.
  func testAFullLayerOfOrdinaryPinsExceedsTheScriptBound() {
    func pin(_ index: Int) -> String {
      #"{"id":"p\#(index)","coordinate":{"latitude":1.5,"longitude":2.5},"label":"Pin \#(index)"}"#
    }

    let full = (0..<CommandPinLimits.maxPinsPerLayer).map(pin).joined(separator: ",")

    XCTAssertGreaterThan(full.utf8.count, ScriptProtocol.maxCommandArgumentBytes)
  }
}
