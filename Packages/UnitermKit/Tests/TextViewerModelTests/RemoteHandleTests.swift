import AppletKit
import XCTest

@testable import TextViewerModel

final class RemoteHandleTests: XCTestCase {
  /// Catches a table that grows without bound, drops a handle a caller still waits on, or keeps the
  /// oldest result instead of the newest.
  func testFullTableDropsTheOldestFinishedHandleAndNeverARunningOne() {
    var table = RemoteHandleTable()

    var ids: [Int] = []

    for _ in 0..<RemoteHandleTable.capacity {
      ids.append(table.open(.scroll) ?? 0)
    }

    XCTAssertFalse(table.hasRoom, "every handle is still running")
    XCTAssertNil(table.open(.scroll))
    XCTAssertEqual(table.entries.count, RemoteHandleTable.capacity)

    XCTAssertTrue(table.settle(ids[5], .done(RemoteLanding())))
    XCTAssertTrue(table.settle(ids[2], .done(RemoteLanding())))
    XCTAssertTrue(table.hasRoom)

    let fresh = table.open(.find)

    XCTAssertEqual(fresh, RemoteHandleTable.capacity + 1)
    XCTAssertNil(table.entry(ids[2]), "the oldest finished handle should go first")
    XCTAssertNotNil(table.entry(ids[5]))
    XCTAssertNotNil(table.entry(ids[0]), "a running handle must stay")
    XCTAssertEqual(table.entries.count, RemoteHandleTable.capacity)
  }

  /// Catches a handle that settles twice and so reports a second outcome, and an active load that
  /// stays set after its handle ends.
  func testAHandleSettlesOnceAndClearsTheActiveLoad() {
    var table = RemoteHandleTable()
    let load = table.open(.load)

    XCTAssertEqual(table.activeLoad, load)
    XCTAssertTrue(table.settle(load ?? 0, .loaded))
    XCTAssertNil(table.activeLoad)
    XCTAssertFalse(table.settle(load ?? 0, .failed(.unreadable)))
    XCTAssertEqual(table.entry(load ?? 0)?.outcome, .loaded)
    XCTAssertFalse(table.settle(99, .loaded))
  }

  /// Catches a reply that names a state outside the contract, or that carries a field it should not.
  func testRepliesCarryOnlyStatesCodesCountsAndAnchors() {
    func reply(_ outcome: RemoteOutcome?) -> JSONValue {
      var table = RemoteHandleTable()
      let id = table.open(.find) ?? 0

      if let outcome { table.settle(id, outcome) }

      return RemoteHandleTable.reply(for: table.entry(id)!)
    }

    XCTAssertEqual(reply(nil), .object(["state": .string("pending")]))
    XCTAssertEqual(reply(.loaded), .object(["state": .string("loaded")]))
    XCTAssertEqual(reply(.superseded), .object(["state": .string("superseded")]))
    XCTAssertEqual(
      reply(.failed(.processEnded)),
      .object(["state": .string("failed"), "code": .string("process-ended")]))
    XCTAssertEqual(
      reply(
        .done(
          RemoteLanding(
            count: 3, capped: false, current: 1, anchor: .markdown(line: 4, fraction: 0.5)))),
      .object([
        "state": .string("done"), "count": .number(3), "capped": .bool(false),
        "current": .number(1),
        "anchor": .object(["kind": .string("line"), "line": .number(4), "fraction": .number(0.5)]),
      ]))
  }

  /// Catches an anchor reader that takes a field from the wrong kind or misses a required one.
  func testAnchorsReadByKindAndRefuseStrayFields() throws {
    XCTAssertEqual(
      try RemoteAnchor(json: .object(["kind": .string("page"), "page": .number(2)])),
      .page(2, x: nil, y: nil))
    XCTAssertEqual(
      try RemoteAnchor(
        json: .object([
          "kind": .string("line"), "line": .number(9), "fraction": .number(0.25),
        ])), .line(9, fraction: 0.25))

    for bad: JSONValue in [
      .object(["kind": .string("line")]),
      .object(["kind": .string("page"), "page": .number(1), "line": .number(1)]),
      .object(["kind": .string("nope")]),
      .null,
    ] {
      XCTAssertThrowsError(try RemoteAnchor(json: bad))
    }
  }

  /// Catches a payload version that an older build would read and then save without the inline
  /// flag, which would lose it. The flag makes version 2 and nothing else does.
  func testOnlyTheInlineFlagRaisesThePayloadVersion() throws {
    let plain = try TextViewerDescription(path: "/a.md", sidebarShown: true).appletDescription()
    let inline = try TextViewerDescription(inlineContent: true).appletDescription()

    XCTAssertEqual(plain.version, TextViewerDescription.baseVersion)
    XCTAssertEqual(inline.version, 2)
    XCTAssertGreaterThan(inline.version, TextViewerDescription.baseVersion)

    XCTAssertEqual(try TextViewerDescription.decode(inline).inlineContent, true)
    XCTAssertEqual(try TextViewerDescription.decode(plain).inlineContent, false)

    guard case .object(let fields) = plain.payload else { return XCTFail("not an object") }

    XCTAssertNil(fields["inlineContent"], "a version 1 payload gains no new field")
  }
}
