import AppletKit
import BrowserTestSupport
import StatusKit
import XCTest

@testable import BrowserApplet

/// Where a download's file work runs and what happens when the user closes the tab while it
/// does. The Downloads folder can be on a network or iCloud volume, so none of it may wait on the
/// main thread. Each test holds an operation with a semaphore, which is the stand-in for a slow
/// volume. The wait is bounded, so a regression fails and does not hang.
@MainActor
final class BrowserDownloadFileWorkTests: XCTestCase {
  /// Holds and records the file operations a download runs.
  final class Operations: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var onMain: [String: Bool] = [:]
    private var finishedURLs: [URL] = []
    private var sweeps: [(folder: URL, now: Date)] = []

    var holdsFinish = false
    var beforeFinish: (@Sendable (URL) -> Void)?

    func note(_ operation: String) {
      lock.withLock { onMain[operation] = Thread.isMainThread }
    }

    var ranOnMain: [String: Bool] { lock.withLock { onMain } }
    var finished: [URL] { lock.withLock { finishedURLs } }
    var sweepCalls: [(folder: URL, now: Date)] { lock.withLock { sweeps } }

    var files: DownloadFileOperations {
      let live = DownloadFileOperations.live

      return DownloadFileOperations(
        prepareFolder: { [self] in
          note("prepare")
          try live.prepareFolder($0)
        },
        finish: { [self] temporary, name, folder, origin, source in
          note("finish")

          if holdsFinish { _ = release.wait(timeout: .now() + 20) }

          beforeFinish?(temporary)

          let url = try live.finish(temporary, name, folder, origin, source)

          lock.withLock { finishedURLs.append(url) }

          return url
        },
        discard: { [self] in
          note("discard")
          live.discard($0)
        },
        sweep: { [self] folder, now in
          note("sweep")
          lock.withLock { sweeps.append((folder, now)) }
          live.sweep(folder, now)
        })
    }
  }

  private nonisolated static let handler: FixtureServer.Handler = { _ in
    FixtureServer.Response(
      status: 200,
      headers: [
        ("Content-Type", "application/octet-stream"),
        ("Content-Disposition", "attachment; filename=\"report.txt\""),
      ], body: Data("hello".utf8))
  }

  private func make(
    _ operations: Operations, sweeper: DownloadSweeper = DownloadSweeper(),
    clock: @escaping @Sendable () -> Date = Date.init
  ) async throws -> BrowserHarness {
    try await BrowserHarness.make(
      services: .testing(files: operations.files, sweeper: sweeper, clock: clock),
      handler: Self.handler)
  }

  private func download(_ harness: BrowserHarness) {
    harness.applet.submit(address: harness.server.url("/file").absoluteString)
  }

  /// Catches a file operation on the main thread. Preparing the folder, naming and marking the
  /// file, and the sweep each run on another thread, and the download still completes.
  func testFileWorkRunsOffTheMainThread() async throws {
    let operations = Operations()
    let harness = try await make(operations)
    defer { harness.stop() }

    download(harness)
    await harness.host.until("the download is announced") { !harness.posts.isEmpty }

    XCTAssertEqual(harness.posts.map(\.text), ["Downloaded report.txt."])
    XCTAssertEqual(
      operations.ranOnMain.filter { $0.value }.keys.sorted(), [], "\(operations.ranOnMain)")
    XCTAssertEqual(Set(operations.ranOnMain.keys), ["prepare", "finish", "sweep"])
  }

  /// Catches a download that stops counting as running while its file is being named, so a close
  /// goes ahead with no question, and an outcome that arrives twice or not at all. While the
  /// finish is held the pane is still running something and the file is not named yet. The
  /// release announces it once.
  func testAFinishingDownloadStillCountsAsRunningAndIsAnnouncedOnce() async throws {
    let operations = Operations()

    operations.holdsFinish = true

    let harness = try await make(operations)
    defer { harness.stop() }

    download(harness)
    await harness.eventually("the finish is under way") {
      harness.applet.downloads.active.first?.isFinalizing == true
    }

    XCTAssertTrue(harness.applet.isRunningSomething)
    XCTAssertEqual(harness.applet.runningLabels, ["report.txt"])
    XCTAssertEqual(harness.posts.count, 0)
    XCTAssertFalse(harness.files().contains("report.txt"))

    operations.release.signal()
    await harness.host.until("the download is announced") { !harness.posts.isEmpty }

    XCTAssertEqual(harness.posts.map(\.text), ["Downloaded report.txt."])
    XCTAssertFalse(harness.applet.isRunningSomething)
    XCTAssertEqual(harness.applet.downloads.latest?.name, "report.txt")
    XCTAssertEqual(harness.files(), ["report.txt"])
  }

  /// Catches a cancel during the finish that announces the file, keeps the file, or leaves the pane
  /// running. The user confirms closing the tab while the finish is held. The pane stops running at
  /// once, nothing is announced, no file is kept, and the finish that completes afterwards is
  /// removed. The download is not offered for reveal.
  func testACancelDuringTheFinishResolvesOnceAndLeavesNothing() async throws {
    let operations = Operations()

    operations.holdsFinish = true

    let harness = try await make(operations)
    defer { harness.stop() }

    harness.applet.openTab()
    download(harness)
    await harness.eventually("the finish is under way") {
      harness.applet.downloads.active.first?.isFinalizing == true
    }

    harness.host.recording.answer = true

    let closed = await harness.applet.closeTab(at: 1)

    XCTAssertEqual(closed, .closed)
    XCTAssertFalse(harness.applet.isRunningSomething)
    XCTAssertTrue(harness.applet.downloads.active.isEmpty)

    operations.release.signal()

    await harness.eventually("the finish made its file") { !operations.finished.isEmpty }
    await harness.eventually("the cancelled file is removed") { harness.files().isEmpty }

    XCTAssertEqual(operations.finished.map(\.lastPathComponent), ["report.txt"])
    XCTAssertEqual(harness.posts.map(\.text), [])
    XCTAssertNil(harness.applet.downloads.latest)
    XCTAssertFalse(harness.applet.hasFinishedDownload)
    XCTAssertEqual(operations.ranOnMain["discard"], false)
  }

  /// Catches a download that fails at its end with no reason. A volume that rejects extended
  /// attributes fails only when the file is marked, after the bytes arrived. The temporary file is
  /// removed at the finish, so the mark fails, and the warning names the file and the reason.
  func testALateFailureNamesTheFileAndTheReasonAndLeavesNoFile() async throws {
    let operations = Operations()

    operations.beforeFinish = { try? FileManager.default.removeItem(at: $0) }

    let harness = try await make(operations)
    defer { harness.stop() }

    download(harness)
    await harness.host.until("the failure is reported") { !harness.posts.isEmpty }

    let text = try XCTUnwrap(harness.posts.first?.text)

    XCTAssertEqual(harness.posts.first?.level, .warning)
    XCTAssertTrue(text.hasPrefix("Could not download report.txt. "), text)
    XCTAssertTrue(text.contains("marked as downloaded"), text)
    XCTAssertEqual(harness.files(), [])
    XCTAssertFalse(harness.applet.isRunningSomething)
    XCTAssertNil(harness.applet.downloads.latest)
  }

  /// Catches a sweep that runs on the main thread, on every download, or with a clock of its own.
  /// It runs once for a folder, at its first download, with the browser's injected clock. The
  /// stale file is removed, and a stale file planted afterwards is left for the next launch.
  func testTheSweepRunsOnceAtTheFirstDownloadWithTheInjectedClock() async throws {
    let operations = Operations()
    let moment = Date(timeIntervalSince1970: 2_000_000_000)
    let harness = try await make(operations, clock: { moment })
    defer { harness.stop() }

    let directory = try XCTUnwrap(harness.downloadsDirectory)

    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let first = directory.appending(path: ".uniterm-download-\(UUID().uuidString).part")

    try Data("x".utf8).write(to: first)

    download(harness)
    await harness.host.until("the download is announced") { !harness.posts.isEmpty }
    await harness.eventually("the stale file is swept") {
      !FileManager.default.fileExists(atPath: first.path)
    }

    XCTAssertEqual(operations.sweepCalls.count, 1)
    XCTAssertEqual(operations.sweepCalls.first?.now, moment)
    XCTAssertEqual(operations.ranOnMain["sweep"], false)

    let second = directory.appending(path: ".uniterm-download-\(UUID().uuidString).part")

    try Data("x".utf8).write(to: second)
    harness.host.recording.forgetSent()
    download(harness)
    await harness.host.until("the second download is announced") { !harness.posts.isEmpty }

    XCTAssertEqual(operations.sweepCalls.count, 1)
    XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
  }
}
