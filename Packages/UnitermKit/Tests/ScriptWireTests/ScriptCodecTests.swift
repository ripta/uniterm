import Foundation
import XCTest

@testable import ScriptWire

/// The script wire codec as the app and the helper share it. These tests prove that every
/// message survives a round trip, that a version mismatch is refused by name, and that each
/// size and value check holds. They cannot prove either side behaves. The integration tests
/// run a real helper for that.
final class ScriptCodecTests: XCTestCase {
  /// One of each call, with and without its optional parts, and an ID at the top of the range.
  static let calls: [ScriptCall] = {
    let top = ScriptProtocol.maxID
    let pane = ScriptTarget.pane(ScriptPaneReference(window: top, pane: 3))
    let tab = ScriptTarget.pane(ScriptPaneReference(window: 1, pane: 2, tab: top))
    let nearest = ScriptTarget.nearest(kind: "data-viewer")

    return [
      .listWindows,
      .listPanes(window: 0),
      .listPanes(window: top),
      .openPane(kind: "terminal", beside: pane, axis: nil, directory: nil, access: .disconnected),
      .openPane(
        kind: "data-viewer", beside: tab, axis: .row, directory: "/synthetic/dir",
        access: .remoteControlled),
      .openPane(
        kind: "browser", beside: nearest, axis: .column, directory: nil, access: .disconnected),
      .openTab(pane: pane, directory: nil),
      .openTab(pane: tab, directory: "/synthetic/tab"),
      .openTab(pane: nearest, directory: nil),
      .send(pane: pane, name: "report.csv", content: Data("a,b\n1,2\n".utf8)),
      .send(pane: tab, name: "empty.txt", content: Data()),
      .send(pane: nearest, name: "near.csv", content: Data("a\n".utf8)),
      .sendCommand(
        pane: pane, appletType: "fixture-slides", schemaVersion: 1, command: "show-slide",
        arguments: #"{"index":2}"#),
      .sendCommand(
        pane: nearest, appletType: "fixture-chart", schemaVersion: UInt32(Int32.max),
        command: "set-series", arguments: "{}"),
    ]
  }()

  private func roundTrip(_ message: ScriptHelperMessage) throws -> ScriptHelperMessage {
    let frame = message.frame()
    let (type, length) = try FrameHeader.parse(frame.prefix(FrameHeader.size))

    XCTAssertEqual(frame.count, FrameHeader.size + length)

    return try ScriptHelperMessage.decode(type: type, body: frame.dropFirst(FrameHeader.size))
  }

  private func roundTrip(_ message: ScriptAppMessage) throws -> ScriptAppMessage {
    let frame = message.frame()
    let (type, length) = try FrameHeader.parse(frame.prefix(FrameHeader.size))

    XCTAssertEqual(frame.count, FrameHeader.size + length)

    return try ScriptAppMessage.decode(type: type, body: frame.dropFirst(FrameHeader.size))
  }

  /// Catches a field that is encoded but decoded into a different value.
  func testEveryHelperMessageRoundTrips() throws {
    var messages: [ScriptHelperMessage] = [
      .hello(version: 7),
      .begin(name: "tidy-up.janet"),
      .begin(name: ""),
      .attach(token: Data((0..<UInt8(ScriptProtocol.tokenBytes)).map { $0 })),
      .replLine("(+ 1 2)"),
      .replLine(""),
      .replEvaluating(true),
      .replEvaluating(false),
      .pong(0),
      .pong(UInt32.max),
      .memoryLimit,
    ]

    for level in ScriptStatusLevel.allCases {
      messages.append(.request(id: 41, call: .postStatus(level: level, text: "synthetic text")))
    }

    messages += Self.calls.map { .request(id: 7, call: $0) }

    for message in messages {
      XCTAssertEqual(try roundTrip(message), message)
    }
  }

  /// Catches a reply whose request ID, failure kind, or payload is lost on the wire.
  func testEveryAppMessageRoundTrips() throws {
    let messages: [ScriptAppMessage] = [
      .hello(version: 7),
      .reply(id: 41, result: .ok(Data())),
      .reply(id: 42, result: .ok(Data([1, 2, 3]))),
      .reply(id: 43, result: .failure(.badArgument, "the level is not known")),
      .reply(id: 44, result: .failure(.refused, "no window")),
      .reply(id: 45, result: .failure(.failed, "")),
      .reply(id: 46, result: .failure(.notFound, "the pane is not open in that window")),
      .attachRefused("synthetic refusal"),
      .history(lines: [], final: true),
      .history(lines: ["(+ 1 2)", "(def x 1)"], final: false),
      .ping(0),
      .ping(UInt32.max),
      .stop,
    ]

    for message in messages {
      XCTAssertEqual(try roundTrip(message), message)
    }
  }

  /// Catches a hello that accepts another version, in either direction. The refusal names both
  /// versions so the message to the user can be exact.
  func testAMismatchedHelloIsRefusedByVersion() {
    XCTAssertThrowsError(
      try ScriptHelperMessage.validateHello(.hello(version: ScriptProtocol.version + 1))
    ) { error in
      XCTAssertEqual(
        error as? WireError,
        .versionMismatch(found: ScriptProtocol.version + 1, expected: ScriptProtocol.version))
    }

    XCTAssertThrowsError(
      try ScriptAppMessage.validateHello(.hello(version: ScriptProtocol.version &+ 2))
    ) { error in
      XCTAssertEqual(
        error as? WireError,
        .versionMismatch(found: ScriptProtocol.version &+ 2, expected: ScriptProtocol.version))
    }

    XCTAssertNoThrow(try ScriptHelperMessage.validateHello(.hello(version: ScriptProtocol.version)))
    XCTAssertNoThrow(try ScriptAppMessage.validateHello(.hello(version: ScriptProtocol.version)))
  }

  /// Catches a connection that starts with anything but a hello and still passes validation.
  func testAFirstMessageThatIsNotAHelloIsRefused() {
    XCTAssertThrowsError(try ScriptHelperMessage.validateHello(.begin(name: "x")))
    XCTAssertThrowsError(
      try ScriptHelperMessage.validateHello(
        .request(id: 1, call: .postStatus(level: .info, text: "x"))))
    XCTAssertThrowsError(
      try ScriptAppMessage.validateHello(.reply(id: 1, result: .ok(Data()))))
  }

  /// Catches a writer that emits a field the reader refuses. The writer cuts text at a character
  /// boundary, so a long message degrades instead of killing the connection.
  func testLongStatusTextIsCutAtACharacterBoundary() throws {
    let text = String(repeating: "\u{00E9}", count: ScriptProtocol.maxStatusBytes)
    let decoded = try roundTrip(.request(id: 1, call: .postStatus(level: .info, text: text)))

    guard case .request(_, .postStatus(_, let carried)) = decoded else {
      return XCTFail("the request did not decode as a status post")
    }

    XCTAssertEqual(carried.utf8.count, ScriptProtocol.maxStatusBytes)
    XCTAssertTrue(text.hasPrefix(carried))
  }

  /// Catches a reader that allocates for a string longer than the limit the sender may write.
  func testAStringPastItsLimitIsRefused() {
    var body = ByteWriter()
    body.put(UInt32(1))
    body.put(UInt16(1))
    body.put(UInt8(0))
    body.put(UInt16(ScriptProtocol.maxStatusBytes + 1))
    body.put(raw: Data(repeating: 0x61, count: ScriptProtocol.maxStatusBytes + 1))

    XCTAssertThrowsError(try ScriptHelperMessage.decode(type: 3, body: body.bytes)) { error in
      XCTAssertEqual(
        error as? WireError,
        .tooLong(
          declared: ScriptProtocol.maxStatusBytes + 1, limit: ScriptProtocol.maxStatusBytes))
    }
  }

  /// Catches a reader that guesses at a call, a level, or a failure kind it does not know, or
  /// that accepts bytes after a message.
  func testUnknownValuesAndTrailingBytesAreRefused() {
    var unknownCall = ByteWriter()
    unknownCall.put(UInt32(1))
    unknownCall.put(UInt16(999))

    XCTAssertThrowsError(try ScriptHelperMessage.decode(type: 3, body: unknownCall.bytes))

    var unknownLevel = ByteWriter()
    unknownLevel.put(UInt32(1))
    unknownLevel.put(UInt16(1))
    unknownLevel.put(UInt8(9))
    unknownLevel.put(string: "x", limit: 16)

    XCTAssertThrowsError(try ScriptHelperMessage.decode(type: 3, body: unknownLevel.bytes))

    var unknownKind = ByteWriter()
    unknownKind.put(UInt32(1))
    unknownKind.put(UInt8(77))
    unknownKind.put(string: "x", limit: 16)

    XCTAssertThrowsError(try ScriptAppMessage.decode(type: 2, body: unknownKind.bytes))

    var trailing = ByteWriter()
    trailing.put(UInt16(1))
    trailing.put(UInt8(0xFF))

    XCTAssertThrowsError(try ScriptHelperMessage.decode(type: 1, body: trailing.bytes)) { error in
      XCTAssertEqual(error as? WireError, .trailingBytes)
    }

    XCTAssertThrowsError(try ScriptHelperMessage.decode(type: 99, body: Data())) { error in
      XCTAssertEqual(error as? WireError, .unknownType(99))
    }

    XCTAssertThrowsError(try ScriptAppMessage.decode(type: 99, body: Data())) { error in
      XCTAssertEqual(error as? WireError, .unknownType(99))
    }
  }
}

extension ScriptCodecTests {
  /// Catches a send that rides in an ordinary frame, which would cap content at the small limit
  /// every other call has, or an ordinary call that rides in the large frame, which would let any
  /// call make the reader allocate a megabyte.
  func testOnlyASendHasTheLargeFrame() throws {
    let pane = ScriptTarget.pane(ScriptPaneReference(window: 1, pane: 2))
    let send = ScriptHelperMessage.request(
      id: 1, call: .send(pane: pane, name: "a.txt", content: Data("x".utf8)))
    let other = ScriptHelperMessage.request(id: 1, call: .listWindows)

    XCTAssertEqual(send.wireType, ScriptHelperMessage.sendType)
    XCTAssertEqual(other.wireType, 3)

    XCTAssertGreaterThan(
      ScriptHelperMessage.bodyLimit(type: ScriptHelperMessage.sendType),
      ScriptProtocol.maxSendBytes)
    XCTAssertEqual(ScriptHelperMessage.bodyLimit(type: 3), ScriptProtocol.maxControlBody)

    let sendFrame = send.frame()
    let otherFrame = other.frame()

    XCTAssertThrowsError(
      try ScriptHelperMessage.decode(type: 3, body: sendFrame.dropFirst(FrameHeader.size)))
    XCTAssertThrowsError(
      try ScriptHelperMessage.decode(
        type: ScriptHelperMessage.sendType, body: otherFrame.dropFirst(FrameHeader.size)))
  }

  /// Catches content past the limit that the decoder still carries, and the largest content that
  /// it refuses.
  func testSentContentIsHeldToItsLimit() throws {
    let pane = ScriptTarget.pane(ScriptPaneReference(window: 1, pane: 2))
    let largest = Data(repeating: 0x61, count: ScriptProtocol.maxSendBytes)

    let message = ScriptHelperMessage.request(
      id: 1, call: .send(pane: pane, name: "a.bin", content: largest))
    let frame = message.frame()
    let (type, length) = try FrameHeader.parse(frame.prefix(FrameHeader.size))

    XCTAssertLessThanOrEqual(length, ScriptHelperMessage.bodyLimit(type: type))
    XCTAssertEqual(
      try ScriptHelperMessage.decode(type: type, body: frame.dropFirst(FrameHeader.size)), message)

    let tooMuch = ScriptHelperMessage.request(
      id: 1,
      call: .send(
        pane: pane, name: "a.bin", content: Data(repeating: 0x61, count: largest.count + 1))
    ).frame()

    XCTAssertThrowsError(
      try ScriptHelperMessage.decode(
        type: ScriptHelperMessage.sendType, body: tooMuch.dropFirst(FrameHeader.size))
    ) { error in
      XCTAssertEqual(
        error as? WireError,
        .tooLong(declared: largest.count + 1, limit: ScriptProtocol.maxSendBytes))
    }
  }

  /// Catches an ID above 2^53 - 1 that reaches the app, where it would name a pane by rounding.
  /// The helper checks the same limit, but the app does not trust it.
  func testAnIDTooLargeForAJanetNumberIsRefused() {
    for id in [ScriptProtocol.maxID + 1, UInt64.max] {
      var body = ByteWriter()
      body.put(UInt32(1))
      body.put(UInt16(3))
      body.put(id: id)

      XCTAssertThrowsError(try ScriptHelperMessage.decode(type: 3, body: body.bytes), "\(id)") {
        XCTAssertEqual(
          $0 as? WireError, .badValue("an ID is too large for a script number"))
      }
    }
  }

  /// Catches a reader that guesses at a split axis, a tab flag, a target form, or a pane access it
  /// does not know.
  func testUnknownAxisAndFlagsAreRefused() {
    var axis = ByteWriter()
    axis.put(UInt32(1))
    axis.put(UInt16(4))
    axis.put(string: "terminal", limit: 32)
    axis.put(target: .pane(ScriptPaneReference(window: 1, pane: 2)))
    axis.put(UInt8(3))
    axis.put(UInt8(0))
    axis.put(UInt8(0))

    XCTAssertThrowsError(try ScriptHelperMessage.decode(type: 3, body: axis.bytes)) {
      XCTAssertEqual($0 as? WireError, .badValue("an unknown split axis"))
    }

    var flag = ByteWriter()
    flag.put(UInt32(1))
    flag.put(UInt16(5))
    flag.put(UInt8(0))
    flag.put(id: 1)
    flag.put(id: 2)
    flag.put(UInt8(2))
    flag.put(UInt8(0))

    XCTAssertThrowsError(try ScriptHelperMessage.decode(type: 3, body: flag.bytes)) {
      XCTAssertEqual($0 as? WireError, .badValue("a reference has an unknown tab flag"))
    }

    var form = ByteWriter()
    form.put(UInt32(1))
    form.put(UInt16(5))
    form.put(UInt8(2))
    form.put(UInt8(0))

    XCTAssertThrowsError(try ScriptHelperMessage.decode(type: 3, body: form.bytes)) {
      XCTAssertEqual($0 as? WireError, .badValue("a target has an unknown form"))
    }

    var access = ByteWriter()
    access.put(UInt32(1))
    access.put(UInt16(4))
    access.put(string: "terminal", limit: 32)
    access.put(target: .nearest(kind: "terminal"))
    access.put(UInt8(0))
    access.put(UInt8(0))
    access.put(UInt8(2))

    XCTAssertThrowsError(try ScriptHelperMessage.decode(type: 3, body: access.bytes)) {
      XCTAssertEqual($0 as? WireError, .badValue("an unknown pane access"))
    }
  }

  /// Catches a reply value that does not survive the bytes the shim reads, including the largest
  /// ID, and nesting that a record of records of arrays needs.
  func testValuesRoundTrip() throws {
    let values: [ScriptValue] = [
      .null,
      .bool(true),
      .bool(false),
      .integer(0),
      .integer(ScriptProtocol.maxID),
      .number(-1.5),
      .number(0.1),
      .number(-Double.greatestFiniteMagnitude),
      .string(""),
      .string("caf\u{00E9} \u{1F600}"),
      .array([]),
      .array([.integer(1), .string("two"), .null]),
      .record([:]),
      .record([
        "window": .integer(9),
        "tabs": .array([.record(["tab": .integer(1), "selected": .bool(true)])]),
      ]),
    ]

    for value in values {
      XCTAssertEqual(try ScriptValue.decode(try value.encoded()), value)
    }
  }

  /// Catches a send-command whose arguments pass the bound, or whose schema version is past the
  /// largest a script can name, being read as a call.
  func testSendCommandBoundsAreRefusedWhenDecoded() {
    var body = ByteWriter()

    body.put(UInt16(7))
    body.put(target: .nearest(kind: "fixture-slides"))
    body.put(string: "fixture-slides", limit: ScriptProtocol.maxKindBytes)
    body.put(UInt32(1))
    body.put(string: "status", limit: ScriptProtocol.maxCommandNameBytes)
    body.put(UInt32(ScriptProtocol.maxCommandArgumentBytes + 1))
    body.put(raw: Data(repeating: 0x20, count: ScriptProtocol.maxCommandArgumentBytes + 1))

    var reader = ByteReader(body.bytes)

    XCTAssertThrowsError(try ScriptCall.decode(from: &reader))

    var version = ByteWriter()

    version.put(UInt16(7))
    version.put(target: .nearest(kind: "fixture-slides"))
    version.put(string: "fixture-slides", limit: ScriptProtocol.maxKindBytes)
    version.put(UInt32(ScriptProtocol.maxSchemaVersion) + 1)
    version.put(string: "status", limit: ScriptProtocol.maxCommandNameBytes)
    version.put(UInt32(2))
    version.put(raw: Data("{}".utf8))

    var versionReader = ByteReader(version.bytes)

    XCTAssertThrowsError(try ScriptCall.decode(from: &versionReader))
  }

  /// Catches a value the shim could not read being sent anyway: an integer a Janet number cannot
  /// hold, a key that is not a name, and nesting past the depth the shim allows.
  func testValuesThatCannotBeSentAreRefusedWhenEncoded() {
    XCTAssertThrowsError(try ScriptValue.integer(ScriptProtocol.maxID + 1).encoded())
    XCTAssertThrowsError(try ScriptValue.record(["two words": .null]).encoded())
    XCTAssertThrowsError(try ScriptValue.record(["": .null]).encoded())
    XCTAssertThrowsError(try ScriptValue.number(.infinity).encoded())
    XCTAssertThrowsError(try ScriptValue.number(.nan).encoded())

    var deep = ScriptValue.null

    for _ in 0...ScriptValue.maxDepth + 1 { deep = .array([deep]) }

    XCTAssertThrowsError(try deep.encoded())
  }

  /// Catches a string past its limit that is carried whole, or cut inside a character.
  func testALongValueStringIsCutAtACharacterBoundary() throws {
    let text = String(repeating: "\u{00E9}", count: ScriptValue.maxStringBytes)

    guard case .string(let carried) = try ScriptValue.decode(try ScriptValue.string(text).encoded())
    else { return XCTFail("the string did not decode as a string") }

    XCTAssertEqual(carried.utf8.count, ScriptValue.maxStringBytes)
    XCTAssertTrue(text.hasPrefix(carried))
  }

  /// Catches a value reader that accepts bytes the shim would have to guess at.
  func testMalformedValuesAreRefused() {
    let bad: [Data] = [
      Data(),
      Data([9]),
      Data([0, 0]),
      Data([3, 0, 0, 0]),
      Data([3, 0, 0x20, 0, 0, 0, 0, 0, 0]),
      Data([4, 0, 0, 0, 5, 0x61]),
      Data([4, 0, 0, 0, 1, 0xFF]),
      Data([5, 0, 2, 0]),
      Data([6, 0, 1, 1, 0x61]),
      Data([6, 0, 1, 0, 0]),
    ]

    for data in bad {
      XCTAssertThrowsError(try ScriptValue.decode(data), "\(Array(data))")
    }
  }
}

extension ScriptCodecTests {
  /// Catches a token of the wrong size being accepted, which would let a helper bind with less
  /// than the entropy the app issued.
  func testATokenOfTheWrongSizeIsRefused() {
    for size in [0, 1, ScriptProtocol.tokenBytes - 1, ScriptProtocol.tokenBytes + 1] {
      XCTAssertThrowsError(
        try ScriptHelperMessage.decode(type: 5, body: Data(repeating: 1, count: size)), "\(size)")
    }
  }

  /// Catches a REPL line past the editor's own limit, an evaluating flag that is not 0 or 1, and a
  /// history that declares more lines per message than the app sends or the helper reads.
  func testReplMessagesRefuseValuesPastTheirLimits() {
    var long = ByteWriter()
    long.put(UInt16(ScriptProtocol.maxReplLineBytes + 1))
    long.put(raw: Data(repeating: 0x61, count: ScriptProtocol.maxReplLineBytes + 1))

    XCTAssertThrowsError(try ScriptHelperMessage.decode(type: 6, body: long.bytes))
    XCTAssertThrowsError(try ScriptHelperMessage.decode(type: 7, body: Data([2])))

    var many = ByteWriter()
    many.put(UInt8(1))
    many.put(UInt16(ScriptProtocol.historyLinesPerMessage + 1))

    XCTAssertThrowsError(try ScriptAppMessage.decode(type: 4, body: many.bytes))
    XCTAssertThrowsError(try ScriptAppMessage.decode(type: 4, body: Data([2, 0, 0])))
  }

  /// Catches a writer whose history message passes the control frame, which the reader would
  /// refuse and so end the REPL before it started.
  func testAFullHistoryMessageFitsTheControlFrame() {
    let line = String(repeating: "x", count: ScriptProtocol.maxReplLineBytes)
    let message = ScriptAppMessage.history(
      lines: Array(repeating: line, count: ScriptProtocol.historyLinesPerMessage), final: true)

    XCTAssertLessThanOrEqual(
      message.frame().count - FrameHeader.size, ScriptProtocol.maxControlBody)
  }
}

extension ScriptCodecTests {
  /// Catches a liveness or stop message that tolerates a body of the wrong size, which a peer could
  /// use to smuggle bytes past the decoder. A ping holds exactly one nonce, a stop and a memory
  /// notice hold nothing, and a pong holds exactly one nonce.
  func testLivenessAndStopMessagesRefuseABodyOfTheWrongSize() {
    for size in [0, 1, 3, 5] {
      XCTAssertThrowsError(
        try ScriptAppMessage.decode(type: 5, body: Data(repeating: 1, count: size)), "ping \(size)")
      XCTAssertThrowsError(
        try ScriptHelperMessage.decode(type: 8, body: Data(repeating: 1, count: size)),
        "pong \(size)")
    }

    XCTAssertThrowsError(try ScriptAppMessage.decode(type: 6, body: Data([0])))
    XCTAssertThrowsError(try ScriptHelperMessage.decode(type: 9, body: Data([0])))
  }

  /// Catches a kill margin that drifts from the cap it is a share of. The app kills a REPL helper
  /// at the cap plus a quarter, which is the 1.25 GiB the design names.
  func testTheKillMarginIsAQuarterOfTheCap() {
    XCTAssertEqual(ScriptProtocol.helperMemoryCap, 1 << 30)
    XCTAssertEqual(ScriptProtocol.helperMemoryCap + ScriptProtocol.footprintKillMargin, 5 << 28)
  }
}
