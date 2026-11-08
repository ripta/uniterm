import XCTest

@testable import ImageWire

final class MessageCodecTests: XCTestCase {
  private func roundTrip(_ message: AppMessage) throws -> AppMessage {
    let frame = message.frame()
    let (type, length) = try FrameHeader.parse(frame.prefix(FrameHeader.size))

    XCTAssertEqual(length, frame.count - FrameHeader.size)

    return try AppMessage.decode(type: type, body: frame.dropFirst(FrameHeader.size))
  }

  private func roundTrip(_ message: HelperMessage) throws -> HelperMessage {
    let frame = message.frame()
    let (type, length) = try FrameHeader.parse(frame.prefix(FrameHeader.size))

    XCTAssertEqual(length, frame.count - FrameHeader.size)

    return try HelperMessage.decode(type: type, body: frame.dropFirst(FrameHeader.size))
  }

  /// Catches a message that does not come back from the codec as it went in. Every case of both
  /// directions is covered, so a field added to one writer and not its reader fails here.
  func testEveryMessageRoundTrips() throws {
    let app: [AppMessage] = [
      .hello(version: 1), .open(source: 7),
      .decode(request: 9, source: 7, maxPixel: 2048, frame: 3), .ping(nonce: 0xDEAD_BEEF),
      .region(request: 4, source: 7, level: 4096, x: 512, y: 1024, width: 512, height: 300),
      .release(source: 7),
    ]

    for message in app {
      XCTAssertEqual(try roundTrip(message), message)
    }

    let header = ImageHeader(
      request: 9, source: 7, frame: 2, width: 3, height: 2, space: .displayP3, format: .rgba8)
    let helper: [HelperMessage] = [
      .hello(version: 1, types: ["public.png", "public.jpeg"]),
      .opened(
        SourceInfo(
          source: 7, width: 640, height: 480, frameDelays: [100, 200, 300], dpiX: 144, dpiY: 72)),
      .image(header, pixels: Data(repeating: 9, count: 24)),
      .failure(request: 9, kind: .unsupportedFormat, text: "No decoder for this HEIC image."),
      .pong(nonce: 5),
    ]

    for message in helper {
      XCTAssertEqual(try roundTrip(message), message)
    }
  }

  /// Catches a body that runs short or long being accepted. A short body would read fields from
  /// nothing, and a long one would hide bytes the reader never looked at.
  func testTruncatedAndTrailingBodiesAreRefused() throws {
    let frame = AppMessage.decode(request: 1, source: 2, maxPixel: 3, frame: 4)
    let body = frame.frame().dropFirst(FrameHeader.size)

    XCTAssertThrowsError(try AppMessage.decode(type: 3, body: body.dropLast())) {
      XCTAssertEqual($0 as? WireError, .truncated)
    }

    XCTAssertThrowsError(try AppMessage.decode(type: 3, body: body + [0])) {
      XCTAssertEqual($0 as? WireError, .trailingBytes)
    }

    XCTAssertThrowsError(try HelperMessage.decode(type: 99, body: Data())) {
      XCTAssertEqual($0 as? WireError, .unknownType(99))
    }
  }

  /// Catches a hello that lists more types than the cap, or a type name past its byte cap. The
  /// helper is untrusted, so a list the writer never produces must still be refused.
  func testAnOversizedTypeListIsRefused() {
    var body = ByteWriter()
    body.put(UInt16(1))
    body.put(UInt16(ImageLimits.maxTypes + 1))

    XCTAssertThrowsError(try HelperMessage.decode(type: 1, body: body.bytes)) {
      XCTAssertEqual(
        $0 as? WireError,
        .tooLong(declared: ImageLimits.maxTypes + 1, limit: ImageLimits.maxTypes))
    }

    var long = ByteWriter()
    long.put(UInt16(1))
    long.put(UInt16(1))
    long.put(UInt16(ImageLimits.maxTypeBytes + 1))
    long.put(raw: Data(repeating: 65, count: ImageLimits.maxTypeBytes + 1))

    XCTAssertThrowsError(try HelperMessage.decode(type: 1, body: long.bytes))
  }

  /// Catches a writer that emits a failure text the reader refuses. A long text is cut at a
  /// character boundary, so the other side always reads what was sent.
  func testALongFailureTextIsCutOnACharacterBoundary() throws {
    let text = String(repeating: "\u{00E9}", count: 400)
    let decoded = try roundTrip(HelperMessage.failure(request: 1, kind: .limit, text: text))

    guard case .failure(_, _, let received) = decoded else { return XCTFail("not a failure") }

    XCTAssertLessThanOrEqual(received.utf8.count, ImageLimits.maxMessageBytes)
    XCTAssertEqual(received, String(repeating: "\u{00E9}", count: received.count))
  }

  /// Catches a helper and an app of different protocol versions agreeing to talk. The refusal
  /// carries the text that tells the user to relaunch uniterm.
  func testAHelloOfAnotherVersionIsRefusedBeforeAnyImageMoves() {
    XCTAssertEqual(
      try HelperHandshake.validate(.hello(version: ImageProtocol.version, types: ["public.png"])),
      ["public.png"])

    XCTAssertThrowsError(try HelperHandshake.validate(.hello(version: 99, types: []))) {
      XCTAssertEqual(
        $0 as? WireError, .versionMismatch(found: 99, expected: ImageProtocol.version))
    }

    XCTAssertThrowsError(try HelperHandshake.validate(.pong(nonce: 1)))
    XCTAssertTrue(ImageProtocol.mismatchText.contains("Relaunch uniterm"))
  }

  /// Catches an image body limit that lets a control message grow as large as an image, or one that
  /// forbids the image the app asked for.
  func testOnlyAnImageMayDeclareALargeBody() {
    XCTAssertEqual(HelperMessage.bodyLimit(type: 3, maxImageBytes: 1000), 1064)
    XCTAssertEqual(
      HelperMessage.bodyLimit(type: 4, maxImageBytes: 1000), ImageProtocol.maxControlBody)
  }
}

/// The protocol version the zoom messages need.
final class ProtocolVersionTests: XCTestCase {
  /// Catches a region request that an older helper would misread. The region and release messages
  /// are new, and a source now carries its resolution, so the version moved to 2. A helper that
  /// still says 1 is refused at the handshake, as any mismatch is.
  func testTheZoomMessagesBumpTheVersionAndAnOlderHelperIsRefused() {
    XCTAssertEqual(ImageProtocol.version, 2)

    XCTAssertThrowsError(try HelperHandshake.validate(.hello(version: 1, types: []))) {
      XCTAssertEqual($0 as? WireError, .versionMismatch(found: 1, expected: 2))
    }
  }

  /// Catches an opened reply that drops the resolution on the way. The app computes actual size
  /// from it, so a lost field would show every Retina screenshot at double size.
  func testAnOpenedReplyCarriesTheDeclaredResolution() throws {
    let info = SourceInfo(source: 1, width: 10, height: 10, frameDelays: [0], dpiX: 144, dpiY: 144)
    let frame = HelperMessage.opened(info).frame()
    let decoded = try HelperMessage.decode(
      type: frame[frame.startIndex], body: frame.dropFirst(FrameHeader.size))

    guard case .opened(let back) = decoded else { return XCTFail("not an opened reply") }

    XCTAssertEqual([back.dpiX, back.dpiY], [144, 144])
  }
}
