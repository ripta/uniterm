import ImageTestSupport
import SourceAccess
import XCTest

@testable import ImageViewerModel

final class FolderScanTests: XCTestCase {
  private var folder: URL!

  override func setUpWithError() throws {
    folder = try ImageFixtures.makeFolder()
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
  }

  private func opened() throws -> OpenedFolder {
    guard case .success(.folder(let opened)) = SourceOpener.open(path: folder.path) else {
      throw XCTSkip("the folder did not open")
    }

    return opened
  }

  /// Catches a scan that reports once at the end, which would make a large folder look empty until
  /// it finishes. Five images in batches of two arrive as three batches and then the end, and the
  /// scan reads on a thread that is not the main one.
  func testAScanReportsInBatchesThenFinishesOffTheMainThread() async throws {
    for index in 0..<5 {
      try ImageFixtures.write(ImageFixtures.png(), named: "img\(index).png", in: folder)
    }

    let sawMainThread = MainThreadSightings()
    let pace = ScanPace(batchSize: 2) { _ in sawMainThread.note(Thread.isMainThread) }

    var sizes: [Int] = []
    var finished = false

    for await update in FolderScan.updates(
      of: try opened(), supporting: SupportedImageTypes(), sort: .name, pace: pace)
    {
      switch update {
      case .batch(let batch): sizes.append(batch.count)
      case .ordered(_, let all): XCTAssertEqual(all.count, 5)
      case .finished: finished = true
      case .failed(let error): XCTFail("\(error)")
      }
    }

    XCTAssertEqual(sizes, [2, 2, 1])
    XCTAssertTrue(finished)
    XCTAssertFalse(sawMainThread.sawMain)
  }

  /// Catches a scan that cannot be held mid-way. A test that blocks the scan between batches sees
  /// the first batch arrive while the scan is still running.
  func testAHeldScanDeliversItsFirstBatchBeforeItEnds() async throws {
    for index in 0..<4 {
      try ImageFixtures.write(ImageFixtures.png(), named: "img\(index).png", in: folder)
    }

    let gate = DispatchSemaphore(value: 0)
    let pace = ScanPace(batchSize: 2) { index in
      if index == 1 { gate.wait() }
    }

    var iterator = FolderScan.updates(
      of: try opened(), supporting: SupportedImageTypes(), sort: .name, pace: pace
    )
    .makeAsyncIterator()

    guard case .batch(let first) = await iterator.next() else { return XCTFail("no first batch") }

    XCTAssertEqual(first.count, 2)

    gate.signal()

    guard case .batch(let second) = await iterator.next() else { return XCTFail("no second batch") }

    XCTAssertEqual(second.count, 2)

    guard case .ordered(.name, let all) = await iterator.next() else {
      return XCTFail("no ordered listing")
    }

    XCTAssertEqual(all.map(\.name), ["img0.png", "img1.png", "img2.png", "img3.png"])

    let end = await iterator.next()

    XCTAssertEqual(end, .finished)
  }
}

private final class MainThreadSightings: @unchecked Sendable {
  private let lock = NSLock()
  private var main = false

  var sawMain: Bool { lock.withLock { main } }

  func note(_ onMain: Bool) {
    lock.withLock { main = main || onMain }
  }
}
