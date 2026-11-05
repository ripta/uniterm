import XCTest

@testable import TableData

/// The session through its public surface: a load, a query, a replacement, and a close, on real
/// files. The waits poll the session's own state, so no test sleeps for a fixed time.
@MainActor
final class TableSessionTests: XCTestCase {
  private func until(
    _ session: TableSession, timeout: Double = 10, _ condition: () -> Bool
  ) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)

    while Date() < deadline {
      if condition() { return true }

      try? await Task.sleep(for: .milliseconds(10))
    }

    return condition()
  }

  private func numbered(rows: Int, in scratch: Scratch, name: String = "n.csv") throws -> URL {
    var text = "id,key\n"
    for index in 0..<rows { text += "\(index),\((index * 7919) % 10007)\n" }

    return try scratch.write(name, text)
  }

  private func texts(_ session: TableSession, column: Int) -> [String] {
    (0..<session.visibleCount).map {
      session.snapshot.text(row: session.selection.row(at: $0), column: column)
    }
  }

  /// Catches a session that never finishes, or one that shows a different count than the file holds.
  func testALoadEndsLoadedWithEveryRow() async throws {
    let scratch = try Scratch(self)
    let session = TableSession(budget: TableBudget(limit: 1 << 30, floor: 1 << 20))

    session.load(.file(try numbered(rows: 50, in: scratch)))

    let done = await until(session) { session.phase == .loaded }
    XCTAssertTrue(done)
    XCTAssertEqual(session.visibleCount, 50)
    XCTAssertEqual(session.snapshot.columns.map(\.title), ["id", "key"])
  }

  /// Catches a restored query that takes effect while rows are still arriving, and a stored sort on
  /// a column the file lacks that survives as an error. The sort waits for the end of the load. The
  /// absent column is dropped and the filter stays.
  func testARestoredQueryWaitsForTheLoadAndDropsAnAbsentColumn() async throws {
    let scratch = try Scratch(self)
    let session = TableSession(budget: TableBudget(limit: 1 << 30, floor: 1 << 20))
    let file = try numbered(rows: 30, in: scratch)

    session.load(
      .file(file),
      restoring: TableQuery(sort: SortSpec(column: .named("gone"), ascending: false), filter: "1"))

    XCTAssertEqual(session.query.sort?.column, .named("gone"))

    let done = await until(session) { session.phase == .loaded }
    XCTAssertTrue(done)

    let filtered = await until(session) { session.visibleCount < 30 }
    XCTAssertTrue(filtered)
    XCTAssertNil(session.query.sort)
    XCTAssertEqual(session.query.filter, "1")

    session.load(
      .file(file),
      restoring: TableQuery(sort: SortSpec(column: .named("id"), ascending: false)))

    let sorted = await until(session) {
      session.phase == .loaded && self.texts(session, column: 0).first == "29"
    }
    XCTAssertTrue(sorted)
    XCTAssertEqual(session.query.sort?.column, .named("id"))
  }

  /// Catches rows that show out of order while a sorted load grows. Every state the view sees
  /// during the load, and after it, is sorted by the key column.
  func testRowsArrivingUnderASortNeverShowOutOfOrder() async throws {
    let scratch = try Scratch(self)
    let session = TableSession(
      budget: TableBudget(limit: 1 << 30, floor: 1 << 20), pageTarget: 2_000)
    let file = try numbered(rows: 60_000, in: scratch)
    var violations = 0
    var observed = 0

    session.onChange = { [unowned session] in
      let keys = (0..<session.visibleCount).compactMap {
        Int(session.snapshot.text(row: session.selection.row(at: $0), column: 1))
      }

      observed += 1

      if session.query.sort != nil, session.selection != .all(count: session.snapshot.rowCount),
        zip(keys, keys.dropFirst()).contains(where: { $0 > $1 })
      {
        violations += 1
      }
    }

    session.load(.file(file))
    session.setSort(SortSpec(column: .named("key"), ascending: true))

    let done = await until(session, timeout: 60) {
      session.phase == .loaded && session.visibleCount == 60_000
        && session.selection != .all(count: 60_000)
    }

    XCTAssertTrue(done)
    XCTAssertGreaterThan(observed, 2)
    XCTAssertEqual(violations, 0)

    let keys = texts(session, column: 1).compactMap { Int($0) }
    XCTAssertEqual(keys, keys.sorted())
  }

  /// Catches a newer file that inherits the old file's sort and filter, and an old load that keeps
  /// writing rows into the new table.
  func testOpeningAnotherFileClearsTheQueryAndTheOldRows() async throws {
    let scratch = try Scratch(self)
    let session = TableSession(budget: TableBudget(limit: 1 << 30, floor: 1 << 20))

    session.load(.file(try numbered(rows: 40, in: scratch, name: "a.csv")))
    _ = await until(session) { session.phase == .loaded }
    session.setFilter("1")
    session.setSort(SortSpec(column: .named("id"), ascending: false))

    let second = try scratch.write("b.csv", "id,key\nx,y\n")
    session.load(.file(second))

    XCTAssertEqual(session.query, TableQuery())

    let done = await until(session) { session.phase == .loaded }
    XCTAssertTrue(done)
    XCTAssertEqual(session.visibleCount, 1)
    XCTAssertEqual(texts(session, column: 0), ["x"])
  }

  /// Catches a close that keeps the pane's memory. Closing mid-load gives every reserved byte back
  /// and stops the rows.
  func testClosingFreesTheBudgetAtOnce() async throws {
    let scratch = try Scratch(self)
    let budget = TableBudget(limit: 1 << 30, floor: 1 << 20)
    let session = TableSession(budget: budget, pageTarget: 1_000)

    session.load(.file(try numbered(rows: 20_000, in: scratch)))
    let reserved = await until(session) { budget.used > 0 }
    XCTAssertTrue(reserved)

    session.close()

    XCTAssertEqual(budget.used, 0)
    XCTAssertEqual(session.phase, .idle)
    XCTAssertEqual(session.visibleCount, 0)
  }

  /// Catches a failed load that loses a stored query. A file that is missing keeps the sort and
  /// filter, so saving the layout does not lose them.
  func testAFailedLoadKeepsTheStoredQuery() async throws {
    let session = TableSession(budget: TableBudget(limit: 1 << 30, floor: 1 << 20))
    let query = TableQuery(sort: SortSpec(column: .named("id"), ascending: true), filter: "x")

    session.fail(.missing(path: "/nope.csv"), restoring: query)

    XCTAssertEqual(session.phase, .failed(.missing(path: "/nope.csv")))
    XCTAssertEqual(session.query, query)
  }

  /// Catches a budget stop that hides which rows are shown. The phase says it stopped, and the
  /// count stays below the file's.
  func testAFileOverTheBudgetStopsAndSortsOnlyWhatItHolds() async throws {
    let scratch = try Scratch(self)
    let budget = TableBudget(limit: 6_000, floor: 0)
    let session = TableSession(budget: budget, pageTarget: 1_000)

    session.load(.file(try numbered(rows: 3_000, in: scratch)))
    let stopped = await until(session) { session.phase == .stoppedAtBudget }
    XCTAssertTrue(stopped)

    let held = session.snapshot.rowCount
    XCTAssertLessThan(held, 3_000)

    session.setSort(SortSpec(column: .named("key"), ascending: true))
    let sorted = await until(session) { session.selection != .all(count: held) }
    XCTAssertTrue(sorted)
    XCTAssertEqual(session.visibleCount, held)
  }
}
