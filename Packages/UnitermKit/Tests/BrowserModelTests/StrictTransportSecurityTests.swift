import XCTest

@testable import BrowserModel

/// The header parser and the list, with no web view and no real time. A self-signed response never
/// reaches the navigation delegate in a test, so the pure layer is where this contract is proved.
final class StrictTransportSecurityTests: XCTestCase {
  private let start = Date(timeIntervalSince1970: 1_800_000_000)

  /// Catches a parser that reads the directive set wrongly. The expected values come from RFC 6797
  /// section 6.1 and its examples, written out by hand.
  func testParsesTheDirectivesOfAValidHeader() {
    let cases: [(header: String, maxAge: Int, subdomains: Bool)] = [
      ("max-age=31536000", 31_536_000, false),
      ("max-age=31536000; includeSubDomains", 31_536_000, true),
      ("max-age=31536000;includeSubDomains;preload", 31_536_000, true),
      ("  Max-Age = 100 ;  INCLUDESUBDOMAINS  ", 100, true),
      ("max-age=\"500\"", 500, false),
      ("includeSubDomains; max-age=5", 5, true),
      ("max-age=0", 0, false),
      ("max-age=5; unknown=thing; other", 5, false),
      ("max-age=5;;", 5, false),
      ("max-age=99999999999999999999", StrictTransportSecurity.maximumAge, false),
    ]

    for (header, maxAge, subdomains) in cases {
      XCTAssertEqual(
        StrictTransportSecurity.parse(header),
        StrictTransportSecurity(maxAge: maxAge, includeSubDomains: subdomains), header)
    }
  }

  /// Catches every HSTS response rewriting the file. A header that moves a live entry's expiry by
  /// under an hour, with plenty of life left, is no change. A move of an hour or more, a change in
  /// `includeSubDomains`, and an entry close to expiry are changes.
  func testASmallMoveOfALiveEntryIsNoChange() {
    var list = HSTSList()

    XCTAssertTrue(list.record(host: "example.com", header: "max-age=1000000", now: start))

    let before = list

    XCTAssertFalse(
      list.record(
        host: "example.com", header: "max-age=1000000", now: start.addingTimeInterval(60)))
    XCTAssertEqual(list, before, "a small move changed the list")

    XCTAssertTrue(
      list.record(
        host: "example.com", header: "max-age=1000000", now: start.addingTimeInterval(7_200)),
      "a move of two hours is a change")
    XCTAssertTrue(
      list.record(
        host: "example.com", header: "max-age=1000000; includeSubDomains",
        now: start.addingTimeInterval(7_201)), "includeSubDomains changed")
  }

  /// Catches the skip hiding a renewal that a short term needs. With under an hour left, every
  /// header moves the expiry, so a short-lived entry never lapses while the server renews it.
  func testAShortTermEntryAlwaysRenews() {
    var list = HSTSList()

    list.record(host: "example.com", header: "max-age=100", now: start)

    XCTAssertTrue(
      list.record(host: "example.com", header: "max-age=100", now: start.addingTimeInterval(50)))
    XCTAssertTrue(list.contains(host: "example.com", now: start.addingTimeInterval(140)))
  }

  /// Catches a malformed header being honoured. RFC 6797 has the browser ignore it whole. A
  /// repeated directive, a missing or non-numeric `max-age`, and a negative one are all invalid.
  func testAnInvalidHeaderIsIgnored() {
    let headers = [
      "", ";", "includeSubDomains", "max-age", "max-age=", "max-age=abc", "max-age=-1",
      "max-age=1.5", "max-age=1; max-age=2", "max-age=1; includeSubDomains; includesubdomains",
      "max-age=\"5", "max-age=5 5", "=5", "max-age=+5",
    ]

    for header in headers {
      XCTAssertNil(StrictTransportSecurity.parse(header), header.debugDescription)
    }
  }

  /// Catches a host that never enters the list, and one that stays past its max-age. The clock is
  /// the test's, so the boundary is exact: a host is covered until the instant it expires.
  func testAHostIsCoveredUntilItsMaxAgeEnds() {
    var list = HSTSList()

    XCTAssertTrue(list.record(host: "example.com", header: "max-age=100", now: start))
    XCTAssertTrue(list.contains(host: "example.com", now: start))
    XCTAssertTrue(list.contains(host: "EXAMPLE.com.", now: start), "case and a trailing dot")
    XCTAssertTrue(list.contains(host: "example.com", now: start.addingTimeInterval(99)))
    XCTAssertFalse(list.contains(host: "example.com", now: start.addingTimeInterval(100)))
    XCTAssertFalse(list.contains(host: "other.com", now: start))
  }

  /// Catches a max-age of zero that keeps the host, and a later header that does not extend an
  /// earlier one. Zero removes the host at once.
  func testMaxAgeZeroRemovesTheHostAndALaterHeaderReplacesTheTerm() {
    var list = HSTSList()

    list.record(host: "example.com", header: "max-age=100", now: start)
    list.record(host: "example.com", header: "max-age=1000", now: start)

    XCTAssertTrue(
      list.contains(host: "example.com", now: start.addingTimeInterval(500)), "extended")

    XCTAssertTrue(list.record(host: "example.com", header: "max-age=0", now: start))
    XCTAssertFalse(list.contains(host: "example.com", now: start))
    XCTAssertTrue(list.entries.isEmpty)

    XCTAssertFalse(
      list.record(host: "example.com", header: "max-age=0", now: start), "nothing to remove")
  }

  /// Catches includeSubDomains that does not reach subdomains, one that reaches a sibling or a
  /// parent, and an entry without it that covers a subdomain.
  func testIncludeSubDomainsCoversSubdomainsOnly() {
    var list = HSTSList()

    list.record(host: "example.com", header: "max-age=100; includeSubDomains", now: start)
    list.record(host: "plain.org", header: "max-age=100", now: start)

    XCTAssertTrue(list.contains(host: "a.example.com", now: start))
    XCTAssertTrue(list.contains(host: "a.b.example.com", now: start))
    XCTAssertFalse(list.contains(host: "badexample.com", now: start), "a suffix is not a parent")
    XCTAssertFalse(list.contains(host: "com", now: start), "a parent is not covered")
    XCTAssertFalse(list.contains(host: "a.plain.org", now: start), "no includeSubDomains")
    XCTAssertTrue(list.contains(host: "plain.org", now: start))
  }

  /// Catches a subdomain's own header being overridden by the parent's lapse, and a parent that
  /// expired still covering. The parent's entry ends at its own time.
  func testAnExpiredParentCoversNothing() {
    var list = HSTSList()

    list.record(host: "example.com", header: "max-age=10; includeSubDomains", now: start)

    XCTAssertFalse(list.contains(host: "a.example.com", now: start.addingTimeInterval(11)))
  }

  /// Catches an IP literal or an empty name entering the list. The protocol covers names only, so
  /// a header from an address records nothing and an address is never covered.
  func testIPAddressesAndEmptyNamesNeverRecord() {
    var list = HSTSList()

    for host in ["127.0.0.1", "10.0.0.5", "::1", "[::1]", "2001:db8::1", "", "."] {
      XCTAssertFalse(list.record(host: host, header: "max-age=100", now: start), host)
      XCTAssertFalse(list.contains(host: host, now: start), host)
    }

    XCTAssertTrue(list.entries.isEmpty)
  }

  /// Catches an invalid header that changes the list. An earlier valid entry survives it.
  func testAnInvalidHeaderLeavesTheListAlone() {
    var list = HSTSList()

    list.record(host: "example.com", header: "max-age=100", now: start)

    XCTAssertFalse(list.record(host: "example.com", header: "max-age=bad", now: start))
    XCTAssertTrue(list.contains(host: "example.com", now: start))
  }

  /// Catches a list that grows without bound, and one that drops the host that lasts longest.
  /// Expired entries go first, then the soonest to expire.
  func testTheListIsBoundedAndKeepsTheLongestLived() {
    var list = HSTSList()

    for index in 0..<(HSTSList.capacity + 10) {
      list.record(host: "h\(index).example", header: "max-age=\(1_000 + index)", now: start)
    }

    XCTAssertEqual(list.entries.count, HSTSList.capacity)
    XCTAssertTrue(list.contains(host: "h\(HSTSList.capacity + 9).example", now: start))
    XCTAssertFalse(list.contains(host: "h0.example", now: start), "the soonest to expire left")
  }

  func testRemoveAllEmptiesTheList() {
    var list = HSTSList()

    list.record(host: "example.com", header: "max-age=100", now: start)
    list.removeAll()

    XCTAssertFalse(list.contains(host: "example.com", now: start))
  }
}

/// The file the list lives in. The clock is injected, and each test uses its own folder.
@MainActor
final class HSTSStoreTests: XCTestCase {
  private var folder: URL!

  override func setUp() async throws {
    folder = FileManager.default.temporaryDirectory
      .appending(path: "uniterm-hsts-\(UUID().uuidString)", directoryHint: .isDirectory)
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: folder)
  }

  private var file: URL { folder.appending(path: HSTSStore.fileName) }

  /// Catches a list that does not survive a relaunch, or one that comes back past its term. A
  /// second store on the same file is the relaunch.
  func testTheListSurvivesARelaunchUntilItsTermEnds() {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    let first = HSTSStore(file: file, now: { start })
    first.record(host: "example.com", header: "max-age=100; includeSubDomains")

    let second = HSTSStore(file: file, now: { start.addingTimeInterval(50) })
    XCTAssertTrue(second.contains(host: "example.com"))
    XCTAssertTrue(second.contains(host: "www.example.com"))

    let later = HSTSStore(file: file, now: { start.addingTimeInterval(101) })
    XCTAssertFalse(later.contains(host: "example.com"))
    XCTAssertEqual(later.count, 0, "an expired entry is not kept")
  }

  /// Catches Clear Website Data leaving the list behind, in memory or on disk.
  func testRemoveAllClearsMemoryAndTheFile() {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let store = HSTSStore(file: file, now: { start })

    store.record(host: "example.com", header: "max-age=100")
    store.removeAll()

    XCTAssertFalse(store.contains(host: "example.com"))
    XCTAssertFalse(HSTSStore(file: file, now: { start }).contains(host: "example.com"))
  }

  /// Catches an unreadable file stopping the browser, and a file from a newer build being read as
  /// this one. Both start empty. Neither throws.
  func testAnUnreadableOrNewerFileStartsEmpty() throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

    try Data("not json".utf8).write(to: file)
    XCTAssertEqual(HSTSStore(file: file).count, 0)

    try Data(#"{"version":99,"list":{"entries":{}}}"#.utf8).write(to: file)
    XCTAssertEqual(HSTSStore(file: file).count, 0)
  }

  /// Catches a header on plain HTTP recording, which anyone on the path could have added, and an
  /// HTTPS response whose header is missing or invalid recording. The response's own address and
  /// header are the inputs, as the navigation delegate reads them.
  func testOnlyAnHTTPSResponseWithAValidHeaderRecords() throws {
    let store = HSTSStore()
    let secure = try XCTUnwrap(URL(string: "https://Secure.example/page?x=1"))
    let plain = try XCTUnwrap(URL(string: "http://plain.example/"))
    let local = try XCTUnwrap(URL(string: "https://127.0.0.1:8443/"))

    store.noteResponse(from: plain, header: "max-age=100")
    store.noteResponse(from: secure, header: nil)
    store.noteResponse(from: secure, header: "max-age=oops")
    store.noteResponse(from: local, header: "max-age=100")

    XCTAssertEqual(store.count, 0)

    store.noteResponse(from: secure, header: "max-age=100; includeSubDomains")

    XCTAssertTrue(store.contains(host: "secure.example"))
    XCTAssertTrue(store.contains(host: "www.secure.example"))
    XCTAssertFalse(store.contains(host: "plain.example"))
  }

  /// Catches a file from a newer build being overwritten and lost. The store reads nothing from
  /// it, keeps what it learns in memory, and never writes while it is present. The bytes survive a
  /// record and a clear.
  func testANewerFileIsNeverOverwritten() throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

    let newer = Data(#"{"version":99,"list":{"entries":{"kept.example":{"future":true}}}}"#.utf8)
    try newer.write(to: file)

    let store = HSTSStore(file: file)

    store.record(host: "example.com", header: "max-age=100")
    XCTAssertTrue(store.contains(host: "example.com"), "this session still hides the offer")

    store.removeAll()

    XCTAssertEqual(try Data(contentsOf: file), newer)
  }

  /// Catches a store with no file touching the disk, and a header that changes nothing writing one.
  func testAnInvalidHeaderWritesNoFile() {
    let store = HSTSStore(file: file)

    store.record(host: "example.com", header: "max-age=bad")

    XCTAssertFalse(FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
  }
}
