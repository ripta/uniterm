import Darwin
import XCTest

@testable import ImageWire

final class FramedSocketTests: XCTestCase {
  /// Catches frames that arrive split, merged, or out of order across the socketpair.
  func testFramesCrossTheSocketInOrder() throws {
    let (left, right) = try FramedSocket.pair()

    try left.send(AppMessage.ping(nonce: 1).frame())
    try left.send(AppMessage.ping(nonce: 2).frame())

    for expected in [UInt32(1), 2] {
      let frame = try right.readFrame { _ in 64 }

      XCTAssertEqual(
        try AppMessage.decode(type: frame.type, body: frame.body), .ping(nonce: expected))
    }
  }

  /// Catches a frame that declares a body past the limit being allocated. The length is checked
  /// before the body is read, so a hostile header cannot make the reader allocate.
  func testAFrameOverTheLimitIsRefusedBeforeItsBodyIsRead() throws {
    let (left, right) = try FramedSocket.pair()

    try left.send(Data([3, 0x7F, 0xFF, 0xFF, 0xFF]))

    XCTAssertThrowsError(try right.readFrame { _ in 1000 }) {
      XCTAssertEqual($0 as? WireError, .tooLong(declared: 0x7FFF_FFFF, limit: 1000))
    }
  }

  /// Catches a descriptor that does not arrive beside its frame, or that arrives unusable. The
  /// file is read through the received descriptor, as the helper reads the image.
  func testADescriptorTravelsBesideAFrameAndReadsTheSameFile() throws {
    let (left, right) = try FramedSocket.pair()
    let path = NSTemporaryDirectory() + "uniterm-wire-\(UUID().uuidString)"
    try Data("pixels".utf8).write(to: URL(fileURLWithPath: path))
    defer { unlink(path) }

    let file = open(path, O_RDONLY)
    defer { close(file) }

    try left.send(AppMessage.open(source: 1).frame(), descriptor: file)
    _ = try right.readFrame { _ in 64 }

    let received = try XCTUnwrap(right.takeDescriptor())
    defer { close(received) }

    var buffer = [UInt8](repeating: 0, count: 6)

    XCTAssertEqual(read(received, &buffer, 6), 6)
    XCTAssertEqual(String(decoding: buffer, as: UTF8.self), "pixels")
    XCTAssertNil(right.takeDescriptor())
  }

  /// Catches an image reply written in two parts decoding differently from the same reply framed
  /// whole. The helper sends the pixels from the buffer they were drawn into, so no joined copy of
  /// a large image is made, and the app reads the frame as one message either way.
  func testAnImageSentInTwoPartsReadsAsOneFrame() throws {
    let (left, right) = try FramedSocket.pair()
    let header = ImageHeader(
      request: 3, source: 1, frame: 0, width: 2, height: 2, space: .sRGB, format: .rgba8)
    let pixels = Data((0..<16).map { UInt8($0) })
    let parts = HelperMessage.imageParts(header, pixels: pixels)

    XCTAssertEqual(parts.pixels, pixels)
    XCTAssertEqual(
      parts.prefix + parts.pixels, HelperMessage.image(header, pixels: pixels).frame())

    try left.send(prefix: parts.prefix, trailer: parts.pixels)

    let frame = try right.readFrame { _ in 1 << 20 }

    XCTAssertEqual(
      try HelperMessage.decode(type: frame.type, body: frame.body), .image(header, pixels: pixels))
  }

  /// Catches a closed peer reading as anything but a clean end. A helper exits on this, so a
  /// crashed app leaves no helper behind.
  func testAClosedPeerReadsAsEndOfFile() throws {
    let (left, right) = try FramedSocket.pair()

    left.shutdownAndClose()

    XCTAssertThrowsError(try right.readFrame { _ in 64 }) {
      XCTAssertEqual($0 as? WireError, .closed)
    }
  }

  /// Catches descriptors beyond the waiting bound piling up in the reader. Extras are closed, so a
  /// peer cannot exhaust the descriptor table by sending them without frames.
  func testDescriptorsBeyondTheWaitingBoundAreClosed() throws {
    let (left, right) = try FramedSocket.pair()
    let null = open("/dev/null", O_RDONLY)
    defer { close(null) }

    for _ in 0..<8 {
      try left.send(AppMessage.ping(nonce: 1).frame(), descriptor: null)
      _ = try right.readFrame { _ in 64 }
    }

    var taken = 0

    while let fd = right.takeDescriptor() {
      close(fd)
      taken += 1
    }

    XCTAssertEqual(taken, 4)
  }
}
