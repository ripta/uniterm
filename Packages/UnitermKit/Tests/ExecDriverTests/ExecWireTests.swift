import AppletKit
import Foundation
import XCTest

@testable import ExecDriver

/// The exec wire's framing and messages, apart from any process. Each bound is checked at its
/// edge, so a bound that drifts by one fails here.
final class ExecWireTests: XCTestCase {
  /// Catches a reader that buffers a whole oversized line before refusing it, or that refuses a
  /// line exactly at the bound.
  func testTheReaderRefusesALongLineBeforeItEndsAndAcceptsOneAtTheBound() throws {
    var reader = ExecFrameReader(maximumFrameBytes: 8)

    XCTAssertEqual(try reader.feed(Array("12345678\n".utf8)), [Data("12345678".utf8)])
    XCTAssertEqual(try reader.feed(Array("1234".utf8)), [])
    XCTAssertEqual(reader.pendingBytes, 4)
    XCTAssertThrowsError(try reader.feed(Array("56789".utf8))) {
      XCTAssertEqual($0 as? ExecWireError, .frameTooLong)
    }
  }

  /// Catches a line split across reads that comes back broken, or a partial line at the end of
  /// the stream that is taken as a message.
  func testLinesJoinAcrossChunksAndAPartialLineAtTheEndIsRefused() throws {
    var reader = ExecFrameReader()

    XCTAssertEqual(try reader.feed(Array("{\"a\"".utf8)), [])
    XCTAssertEqual(try reader.feed(Array(":1}\n{\"b\"".utf8)), [Data("{\"a\":1}".utf8)])
    XCTAssertThrowsError(try reader.finish()) {
      XCTAssertEqual($0 as? ExecWireError, .partialFrameAtEOF)
    }
  }

  /// Catches a decoder that takes a message with the wrong shape, or that lets nesting or a value
  /// count past their bounds reach the JSON decoder.
  func testTheDecoderRefusesBadShapesAndPassesNoBoundOn() throws {
    let refused = [
      "not json", "[1]", #"{"type":"hello"}"#, #"{"type":"unheard"}"#,
      #"{"type":"command","id":1.5,"name":"x"}"#, #"{"type":"command","id":1,"name":""}"#,
      #"{"type":"command","id":1,"name":"x","arguments":[1]}"#,
      String(repeating: "[", count: ExecProtocol.maxDepth + 1),
      "[" + Array(repeating: "1", count: ExecProtocol.maxValues + 1).joined(separator: ","),
    ]

    for line in refused {
      XCTAssertThrowsError(try ExecWire.decode(Data(line.utf8)), String(line.prefix(40)))
    }

    XCTAssertEqual(
      try ExecWire.decode(Data(#"{"type":"command","id":"r1","name":"status"}"#.utf8)),
      .command(id: .string("r1"), name: "status", arguments: .object([:])))
  }

  /// Catches a frame for the driver that holds a raw newline, which would split one message into
  /// two, or that loses the request ID a reply must carry back.
  func testAppFramesAreOneLineAndCarryTheRequestID() throws {
    let frame = ExecWire.frame(
      .reply(id: .number(7), result: .object(["text": .string("two\nlines")])))

    XCTAssertEqual(frame.filter { $0 == 0x0A }.count, 1)
    XCTAssertEqual(frame.last, 0x0A)

    let decoded = try JSONDecoder().decode(JSONValue.self, from: frame.dropLast())

    XCTAssertEqual(
      decoded,
      .object([
        "type": .string("reply"), "id": .number(7),
        "result": .object(["text": .string("two\nlines")]),
      ]))
  }

  /// Catches a base environment that takes anything from uniterm's own environment, or that
  /// lets a declared value fail to replace a base one.
  func testTheBaseEnvironmentIsOnlyTheDocumentedFive() throws {
    let base = ExecEnvironment(
      home: "/Users/synthetic", user: "synthetic", temporaryDirectory: "/t/")

    XCTAssertEqual(
      base.environment(adding: ["PATH": "/opt/bin", "TOKEN": "x"]),
      [
        "HOME": "/Users/synthetic", "USER": "synthetic", "LOGNAME": "synthetic", "TMPDIR": "/t/",
        "PATH": "/opt/bin", "TOKEN": "x",
      ])

    let current = try XCTUnwrap(ExecEnvironment.current())

    XCTAssertEqual(Set(current.base.keys), ["HOME", "USER", "LOGNAME", "TMPDIR", "PATH"])
    XCTAssertEqual(current.base["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
  }
}
