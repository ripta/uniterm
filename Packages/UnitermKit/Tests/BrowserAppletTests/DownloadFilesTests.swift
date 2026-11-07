import CoreServices
import XCTest

@testable import BrowserApplet

/// The files a download leaves behind, driven with plain files and no web view.
final class DownloadFilesTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appending(
      path: "uniterm-test-files-\(UUID().uuidString)", directoryHint: .isDirectory)

    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: directory)
  }

  private func temporary(_ text: String = "x") throws -> URL {
    let url = DownloadFiles.temporaryURL(in: directory)

    try Data(text.utf8).write(to: url)

    return url
  }

  private func names() throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
  }

  /// Catches a temporary name that looks like a finished file, or two downloads that share one.
  func testTemporaryNamesAreHiddenAndNeverRepeat() {
    let urls = (0..<50).map { _ in DownloadFiles.temporaryURL(in: directory) }

    XCTAssertEqual(Set(urls).count, 50)

    for url in urls {
      XCTAssertEqual(
        url.deletingLastPathComponent().standardizedFileURL, directory.standardizedFileURL)
      XCTAssertTrue(url.lastPathComponent.hasPrefix(".uniterm-download-"))
      XCTAssertTrue(url.lastPathComponent.hasSuffix(".part"))
    }
  }

  /// Catches a finished file that is not marked, so Gatekeeper never checks it, and one that keeps
  /// its temporary name. The mark is read back.
  func testAFinishedFileIsMarkedAndTakesItsName() throws {
    let temp = try temporary("body")

    let final = try DownloadFiles.finish(
      temporary: temp, name: "a.txt", in: directory,
      origin: URL(string: "https://example.com/page"), source: URL(string: "https://example.com/a"))

    XCTAssertEqual(final.lastPathComponent, "a.txt")
    XCTAssertEqual(try names(), ["a.txt"])
    XCTAssertEqual(try String(contentsOf: final, encoding: .utf8), "body")

    let mark = try XCTUnwrap(
      try final.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties)

    XCTAssertEqual(
      mark[kLSQuarantineTypeKey as String] as? String, kLSQuarantineTypeWebDownload as String)
    XCTAssertEqual(
      mark[kLSQuarantineAgentBundleIdentifierKey as String] as? String,
      DownloadFiles.agentBundleIdentifier)
  }

  /// Catches a name that overwrites a file already there. Each take of a name moves to the next
  /// number, and the first file keeps its bytes.
  func testAnExistingNameIsNeverOverwritten() throws {
    let first = try DownloadFiles.finish(
      temporary: try temporary("one"), name: "a.txt", in: directory, origin: nil, source: nil)
    let second = try DownloadFiles.finish(
      temporary: try temporary("two"), name: "a.txt", in: directory, origin: nil, source: nil)

    XCTAssertEqual(first.lastPathComponent, "a.txt")
    XCTAssertEqual(second.lastPathComponent, "a 2.txt")
    XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "one")
    XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "two")
  }

  /// Catches a check followed by a rename, where two downloads both see a name free and one
  /// overwrites the other. Many threads finish into one name together, as panes in several
  /// windows would, and each gets a name of its own with its own bytes.
  func testConcurrentFinishesNeverTakeTheSameName() throws {
    let count = 32
    let temps = try (0..<count).map { try temporary("body-\($0)") }
    let results = NSLock()
    nonisolated(unsafe) var finals: [URL] = []
    nonisolated(unsafe) var failures: [any Error] = []
    let directory = self.directory!

    DispatchQueue.concurrentPerform(iterations: count) { index in
      do {
        let url = try DownloadFiles.finish(
          temporary: temps[index], name: "same.bin", in: directory, origin: nil, source: nil)

        results.withLock { finals.append(url) }
      } catch {
        results.withLock { failures.append(error) }
      }
    }

    XCTAssertTrue(failures.isEmpty, "\(failures)")
    XCTAssertEqual(Set(finals).count, count)
    XCTAssertEqual(try names().count, count)

    let bodies = try finals.map { try String(contentsOf: $0, encoding: .utf8) }

    XCTAssertEqual(Set(bodies), Set((0..<count).map { "body-\($0)" }))
  }

  /// Catches a rename that fails and leaves the caller thinking the file landed.
  func testAMissingTemporaryFileFails() {
    let missing = DownloadFiles.temporaryURL(in: directory)

    XCTAssertThrowsError(
      try DownloadFiles.finish(
        temporary: missing, name: "a.txt", in: directory, origin: nil, source: nil))
    XCTAssertEqual((try? names()) ?? ["x"], [])
  }

  /// Catches a record that names the wrong addresses, or one that carries a `data:` address, which
  /// is the file's own bytes, or an address too long for an extended attribute.
  func testTheRecordNamesTheOriginAndTheDataAddress() throws {
    let origin = try XCTUnwrap(URL(string: "https://example.com/page"))
    let source = try XCTUnwrap(URL(string: "https://example.com/file"))
    let record = DownloadFiles.quarantineProperties(origin: origin, source: source)

    XCTAssertEqual(record[kLSQuarantineOriginURLKey as String] as? URL, origin)
    XCTAssertEqual(record[kLSQuarantineDataURLKey as String] as? URL, source)
    XCTAssertEqual(
      record[kLSQuarantineTypeKey as String] as? String, kLSQuarantineTypeWebDownload as String)
    XCTAssertEqual(
      record[kLSQuarantineAgentBundleIdentifierKey as String] as? String,
      DownloadFiles.agentBundleIdentifier)

    let data = DownloadFiles.quarantineProperties(
      origin: origin, source: URL(string: "data:text/plain,secret"))

    XCTAssertNil(data[kLSQuarantineDataURLKey as String])
    XCTAssertNotNil(data[kLSQuarantineOriginURLKey as String])

    let long = DownloadFiles.quarantineProperties(
      origin: URL(string: "https://example.com/" + String(repeating: "a", count: 3000)),
      source: nil)

    XCTAssertNil(long[kLSQuarantineOriginURLKey as String])
    XCTAssertNil(
      DownloadFiles.quarantineProperties(origin: nil, source: nil)[
        kLSQuarantineOriginURLKey as String])
  }

  func testDiscardRemovesAPartialFileAndForgivesAMissingOne() throws {
    let temp = try temporary()

    DownloadFiles.discard(temp)
    DownloadFiles.discard(temp)

    XCTAssertEqual(try names(), [])
  }

  // MARK: Sweep

  private func plant(_ name: String, age: TimeInterval, now: Date, directory: Bool = false) throws {
    let url = self.directory.appending(
      path: name, directoryHint: directory ? .isDirectory : .notDirectory)

    if directory {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    } else {
      try Data("x".utf8).write(to: url)
    }

    try FileManager.default.setAttributes(
      [.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
  }

  /// Catches a sweep that removes a file it does not own, or one a live download may still be
  /// writing. Only a regular file of the exact temporary name, older than the age, goes. A user's
  /// file that resembles the name, a directory with the name, a fresh temporary file, and an
  /// ordinary old file all stay. The clock is injected.
  func testTheSweepRemovesOnlyOldFilesOfTheExactName() throws {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let eight = 8 * 24 * 60 * 60.0
    let stale = ".uniterm-download-\(UUID().uuidString).part"
    let fresh = ".uniterm-download-\(UUID().uuidString).part"
    let directoryNamed = ".uniterm-download-\(UUID().uuidString).part"
    let resembling = [
      ".uniterm-download-notes.part", ".uniterm-download-.part",
      ".uniterm-download-\(UUID().uuidString.lowercased()).part",
      ".uniterm-download-\(UUID().uuidString).part.txt",
      "uniterm-download-\(UUID().uuidString).part",
      "report.pdf",
    ]

    try plant(stale, age: eight, now: now)
    try plant(fresh, age: 60, now: now)
    try plant(directoryNamed, age: eight, now: now, directory: true)

    for name in resembling { try plant(name, age: eight, now: now) }

    XCTAssertEqual(DownloadFiles.sweepStale(in: directory, now: now), 1)

    let left = Set(try names())

    XCTAssertFalse(left.contains(stale))
    XCTAssertTrue(left.contains(fresh))
    XCTAssertTrue(left.contains(directoryNamed))

    for name in resembling { XCTAssertTrue(left.contains(name), name) }

    XCTAssertEqual(DownloadFiles.sweepStale(in: directory, now: now), 0)
    XCTAssertEqual(DownloadFiles.sweepStale(in: directory.appending(path: "missing"), now: now), 0)
  }

  /// Catches a name check that accepts a lowercase or malformed identifier.
  func testOnlyTheNamesTheBrowserMakesAreTemporaryNames() {
    XCTAssertTrue(
      DownloadFiles.isTemporaryName(DownloadFiles.temporaryURL(in: directory).lastPathComponent))
    XCTAssertFalse(DownloadFiles.isTemporaryName(".uniterm-download-.part"))
    XCTAssertFalse(DownloadFiles.isTemporaryName("x"))
  }

  /// Catches a folder that cannot take the mark failing with no reason. A file that cannot be
  /// marked, as on a volume with no extended attributes, fails the download at its end with an error
  /// that names the mark and carries the system's reason. A missing file stands in for the
  /// refusal, since a test cannot make a volume reject extended attributes.
  func testAFileThatCannotBeMarkedFailsWithTheReason() {
    let missing = DownloadFiles.temporaryURL(in: directory)

    do {
      _ = try DownloadFiles.finish(
        temporary: missing, name: "a.txt", in: directory, origin: nil, source: nil)

      XCTFail("a file that cannot be marked finished")
    } catch let failure as DownloadFiles.Failure {
      guard case .quarantine(let reason) = failure else { return XCTFail("\(failure)") }

      XCTAssertFalse(reason.isEmpty)

      let text = failure.localizedDescription

      XCTAssertTrue(text.contains("marked as downloaded"), text)
      XCTAssertTrue(text.contains("extended attributes"), text)
      XCTAssertTrue(text.contains(reason), text)
    } catch {
      XCTFail("\(error)")
    }
  }
}
