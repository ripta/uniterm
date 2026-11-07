import Foundation
import ImageTestSupport
import ImageWire
import XCTest

@testable import ImageDecoding

/// Runs the helper's protocol loop in process, over a real socketpair. The test plays the app's
/// side with the shipped codec, so these tests prove the protocol and not a mock of it.
final class HelperServerTests: XCTestCase {
  /// Where the server's thread reports that its loop ended.
  private final class Ending: @unchecked Sendable {
    var status: Int32?
    private let done = DispatchSemaphore(value: 0)
    private var waited = false

    func finish(_ value: Int32) {
      status = value
      done.signal()
    }

    /// True when the loop has ended. Waits only the first time it is asked.
    func ended(within seconds: Double = 5) -> Bool {
      if waited { return status != nil }

      waited = done.wait(timeout: .now() + seconds) == .success

      return waited
    }
  }

  private var app: FramedSocket!
  private let ending = Ending()

  override func setUpWithError() throws {
    let (appEnd, helperEnd) = try FramedSocket.pair()
    app = appEnd

    let server = ImageHelperServer(socket: helperEnd, types: ["public.png", "public.jpeg"])

    let ending = ending

    Thread.detachNewThread {
      ending.finish(server.run())
    }
  }

  override func tearDown() {
    app.shutdownAndClose()
    _ = ending.ended()
  }

  private func read() throws -> HelperMessage {
    let frame = try app.readFrame { HelperMessage.bodyLimit(type: $0, maxImageBytes: 1 << 24) }

    return try HelperMessage.decode(type: frame.type, body: frame.body)
  }

  private func openFile(_ data: Data, source: UInt32) throws {
    let path = NSTemporaryDirectory() + "uniterm-server-\(UUID().uuidString)"
    try data.write(to: URL(fileURLWithPath: path))
    defer { unlink(path) }

    let descriptor = open(path, O_RDONLY)
    defer { close(descriptor) }

    try app.send(AppMessage.open(source: source).frame(), descriptor: descriptor)
  }

  /// Catches a helper that does not start with its version and its types, or that answers a ping
  /// late. The first message is a hello, and a ping comes back as a pong with the same nonce.
  func testTheHelperSaysHelloFirstAndAnswersPings() throws {
    XCTAssertEqual(
      try read(), .hello(version: ImageProtocol.version, types: ["public.png", "public.jpeg"]))

    try app.send(AppMessage.ping(nonce: 77).frame())

    XCTAssertEqual(try read(), .pong(nonce: 77))
  }

  /// Catches a source that opens but does not decode to the size asked for. The app opens a PNG by
  /// descriptor, asks for 32 pixels, and gets 32 by 16 back, which passes its own checks.
  func testAnOpenedSourceDecodesToTheRequestedSizeAndPassesTheAppsChecks() throws {
    _ = try read()
    try openFile(ImageFixtures.png(width: 128, height: 64), source: 5)

    guard case .opened(let info) = try read() else { return XCTFail("no opened reply") }

    XCTAssertEqual([info.source, info.width, info.height], [5, 128, 64])

    try app.send(AppMessage.decode(request: 1, source: 5, maxPixel: 32, frame: 0).frame())

    guard case .image(let header, let pixels) = try read() else { return XCTFail("no image") }

    let expectation = ImageExpectation(
      request: 1, source: 5, frame: 0, maxPixel: 32, sourceWidth: 128, sourceHeight: 64,
      byteCap: 1 << 20)

    XCTAssertNoThrow(try expectation.validate(header, pixels: pixels))
    XCTAssertEqual([header.width, header.height], [32, 16])
  }

  /// Catches a decode that names a source the helper no longer holds. A newer open replaces the
  /// source, and a decode for the older one fails as stale instead of showing the wrong picture.
  func testADecodeForAReplacedSourceFailsAsStale() throws {
    _ = try read()
    try openFile(ImageFixtures.png(), source: 1)
    _ = try read()

    try app.send(AppMessage.decode(request: 2, source: 9, maxPixel: 0, frame: 0).frame())

    guard case .failure(let request, let kind, _) = try read() else { return XCTFail("no failure") }

    XCTAssertEqual(
      [request, UInt32(kind.rawValue)], [2, UInt32(FailureKind.staleSource.rawValue)])
  }

  /// Catches a helper that forgets the image on screen when the next one is opened for a prefetch,
  /// and one that keeps every source forever. Sources decode by ID while they are kept, and the one
  /// decoded longest ago is dropped past the limit, so a decode for it fails as stale.
  func testTheHelperKeepsSeveralSourcesAndDropsTheOneUsedLongestAgo() throws {
    _ = try read()

    let kept = ImageProtocol.retainedSources

    for source in 1...UInt32(kept) {
      try openFile(ImageFixtures.png(), source: source)

      guard case .opened = try read() else { return XCTFail("no opened reply for \(source)") }
    }

    try app.send(AppMessage.decode(request: 1, source: 1, maxPixel: 16, frame: 0).frame())

    guard case .image = try read() else { return XCTFail("the first source was dropped early") }

    try openFile(ImageFixtures.png(), source: UInt32(kept) + 1)

    guard case .opened = try read() else { return XCTFail("no opened reply") }

    try app.send(AppMessage.decode(request: 2, source: 2, maxPixel: 16, frame: 0).frame())

    guard case .failure(_, let kind, _) = try read() else { return XCTFail("source 2 survived") }

    XCTAssertEqual(kind, .staleSource)

    try app.send(AppMessage.decode(request: 3, source: 1, maxPixel: 16, frame: 0).frame())

    guard case .image = try read() else { return XCTFail("the source used last was dropped") }
  }

  /// Catches an open that arrives without a descriptor. The helper reports it and keeps serving.
  func testAnOpenWithoutADescriptorIsReported() throws {
    _ = try read()
    try app.send(AppMessage.open(source: 1).frame())

    guard case .failure(_, let kind, _) = try read() else { return XCTFail("no failure") }

    XCTAssertEqual(kind, .noSource)

    try app.send(AppMessage.ping(nonce: 1).frame())

    XCTAssertEqual(try read(), .pong(nonce: 1))
  }

  /// Catches a helper that outlives its app. When the socket closes, the loop ends with status
  /// zero, so a crashed app leaves no helper decoding behind it.
  func testTheHelperExitsWhenTheSocketCloses() throws {
    _ = try read()

    app.shutdownAndClose()

    XCTAssertTrue(ending.ended())
    XCTAssertEqual(ending.status, 0)
  }

  /// Catches a helper that accepts a hello of another version and carries on. It ends instead, so
  /// the two sides never exchange images they read differently.
  func testTheHelperEndsOnAHelloOfAnotherVersion() throws {
    _ = try read()
    try app.send(AppMessage.hello(version: 99).frame())

    XCTAssertTrue(ending.ended())
    XCTAssertEqual(ending.status, 4)
  }
}
