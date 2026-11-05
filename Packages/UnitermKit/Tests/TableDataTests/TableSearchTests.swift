import XCTest

@testable import TableData

/// Search through the engine and through the session that runs it off the main thread. The files
/// are real, and the waits poll the session's own state.
@MainActor
final class TableSearchTests: XCTestCase {
  private let text = "name,note\nAnna,blue\nbob,Blue sky\ncarl,red\ndora,navy blue\n"

  private func loadedSession(_ scratch: Scratch, _ csv: String? = nil) async throws
    -> TableSession
  {
    let session = TableSession(budget: TableBudget(limit: 1 << 30, floor: 1 << 20))
    session.load(.file(try scratch.write("t.csv", csv ?? text)))

    let done = await eventually { session.phase == .loaded }
    XCTAssertTrue(done)

    return session
  }

  private func eventually(timeout: Double = 10, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)

    while Date() < deadline {
      if condition() { return true }

      try? await Task.sleep(for: .milliseconds(10))
    }

    return condition()
  }

  private func places(_ session: TableSession) -> [String] {
    (0..<session.matches.count).map {
      let place = session.matches.position(at: $0)
      return "\(place.row),\(place.column)"
    }
  }

  /// Catches a search that is case sensitive, that reads the wrong cell, or that lists matches out
  /// of reading order. The engine finds every cell holding the text, row by row.
  func testTheEngineFindsCellsIgnoringCaseInReadingOrder() async throws {
    let session = try await loadedSession(try Scratch(self))

    let found = TableSearchEngine.run(
      session.snapshot, selection: session.selection, query: "BLUE")

    XCTAssertEqual(found?.count, 3)
    XCTAssertEqual(found?.contains(row: 0, column: 1), true)
    XCTAssertEqual(found?.contains(row: 1, column: 1), true)
    XCTAssertEqual(found?.contains(row: 3, column: 1), true)
    XCTAssertEqual(found?.contains(row: 0, column: 0), false)
    XCTAssertEqual(found?.isTruncated, false)
  }

  /// Catches a search that runs past its limit or reports a clipped list as complete. The list
  /// stops at the limit and says so.
  func testTheEngineStopsAtItsLimitAndSaysSo() async throws {
    let session = try await loadedSession(try Scratch(self))

    let found = TableSearchEngine.run(
      session.snapshot, selection: session.selection, query: "a", limit: 2)

    XCTAssertEqual(found?.count, 2)
    XCTAssertEqual(found?.isTruncated, true)
  }

  /// Catches a cancelled search that returns a partial list as if it were complete.
  func testACancelledSearchReturnsNothing() async throws {
    let session = try await loadedSession(try Scratch(self))

    let found = TableSearchEngine.run(
      session.snapshot, selection: session.selection, query: "blue", isCancelled: { true })

    XCTAssertNil(found)
  }

  /// Catches a search that ignores the filter, or that numbers rows by the file and not by the
  /// rows shown. With "blue" filtered to the rows holding "sky" or "navy", the matches are at the
  /// shown positions 0 and 1, whatever their place in the file.
  func testSearchReadsTheFilteredRowsAndNumbersThemAsShown() async throws {
    let session = try await loadedSession(try Scratch(self))

    session.setFilter("y")
    let filtered = await eventually { session.visibleCount == 2 }
    XCTAssertTrue(filtered)

    session.setFind("blue")
    let found = await eventually { session.matches.count == 2 }
    XCTAssertTrue(found)
    XCTAssertEqual(places(session), ["0,1", "1,1"])
    XCTAssertEqual(session.findQuery, "blue")
    XCTAssertEqual(session.query.filter, "y")
  }

  /// Catches a filter change that leaves old matches on rows that moved. When the filter widens,
  /// the search runs again over the rows now shown.
  func testAChangeOfFilterSearchesTheNewRows() async throws {
    let session = try await loadedSession(try Scratch(self))

    session.setFilter("y")
    session.setFind("blue")
    let first = await eventually { session.matches.count == 2 && !session.isSearching }
    XCTAssertTrue(first)

    session.setFilter("")
    let second = await eventually { session.matches.count == 3 && !session.isSearching }
    XCTAssertTrue(second)
    XCTAssertEqual(places(session), ["0,1", "1,1", "3,1"])
  }

  /// Catches a newer query that an older search overwrites. The last query set is the one whose
  /// matches the session ends with.
  func testANewerQueryWinsOverAnOlderOne() async throws {
    let session = try await loadedSession(try Scratch(self))

    session.setFind("blue")
    session.setFind("red")

    let done = await eventually { !session.isSearching }
    XCTAssertTrue(done)
    XCTAssertEqual(places(session), ["2,1"])
  }

  /// Catches stepping that stops at the ends or loses the current match. Next and previous wrap, and
  /// the current cell reads as current.
  func testSteppingWrapsAroundTheMatches() async throws {
    let session = try await loadedSession(try Scratch(self))

    session.setFind("blue")
    let found = await eventually { session.matches.count == 3 }
    XCTAssertTrue(found)
    XCTAssertEqual(session.currentMatch, 0)
    XCTAssertEqual(session.matchState(row: 0, column: 1), .current)
    XCTAssertEqual(session.matchState(row: 1, column: 1), .match)
    XCTAssertEqual(session.matchState(row: 2, column: 1), .none)

    session.stepMatch(forward: true)
    session.stepMatch(forward: true)
    XCTAssertEqual(session.currentMatch, 2)

    session.stepMatch(forward: true)
    XCTAssertEqual(session.currentMatch, 0)

    session.stepMatch(forward: false)
    XCTAssertEqual(session.currentMatch, 2)
  }

  /// Catches a new file that keeps the old file's find query. Loading starts with no query and no
  /// matches, as it starts with no sort and no filter.
  func testLoadingAnotherFileClearsTheFind() async throws {
    let scratch = try Scratch(self)
    let session = try await loadedSession(scratch)

    session.setFind("blue")
    let found = await eventually { session.matches.count == 3 }
    XCTAssertTrue(found)

    session.load(.file(try scratch.write("u.csv", "name,note\nz,blue\n")))
    XCTAssertEqual(session.findQuery, "")
    XCTAssertTrue(session.matches.isEmpty)
    XCTAssertNil(session.currentMatch)
  }

  // MARK: Place

  private func table(_ tag: (Int) -> String) -> String {
    "id,tag\n" + (0..<10).map { "\($0),\(tag($0))\n" }.joined()
  }

  private var evenOdd: String { table { $0 % 2 == 0 ? "ab-even" : "ab-odd" } }

  private func settled(_ session: TableSession) async {
    let done = await eventually { !session.isSearching }
    XCTAssertTrue(done)
  }

  private func currentRow(_ session: TableSession) -> Int? {
    session.currentMatch.map { session.matches.position(at: $0).row }
  }

  private func stepTo(_ session: TableSession, index: Int) {
    for _ in 0..<index { session.stepMatch(forward: true) }
  }

  /// Catches a longer or shorter form of the same word that jumps back to the first match. With the
  /// current match on row 5, "ab" becoming "abc" keeps row 5 among the odd rows, and deleting the
  /// letter again keeps it among all rows.
  func testExtendingOrShorteningTheWordKeepsThePlace() async throws {
    let session = try await loadedSession(
      try Scratch(self), table { $0 % 2 == 0 ? "ab" : "abc" })

    session.setFind("ab")
    await settled(session)
    stepTo(session, index: 5)
    XCTAssertEqual(currentRow(session), 5)

    session.setFind("abc")
    await settled(session)
    XCTAssertEqual(session.matches.count, 5)
    XCTAssertEqual(currentRow(session), 5, "the place was lost")

    session.setFind("ab")
    await settled(session)
    XCTAssertEqual(currentRow(session), 5)
  }

  /// Catches a place kept by position in the rows shown, which a filter moves. The current match
  /// stays on the same row of the file. When that row is filtered out, the next row's match takes
  /// over.
  func testAFilterKeepsTheCurrentRowOfTheFile() async throws {
    let session = try await loadedSession(try Scratch(self), evenOdd)

    session.setFind("ab")
    await settled(session)
    stepTo(session, index: 7)

    session.setFilter("odd")
    let odd = await eventually { session.visibleCount == 5 }
    XCTAssertTrue(odd)
    await settled(session)
    XCTAssertEqual(currentRow(session), 3, "row 7 of the file is the fourth odd row")

    session.setFilter("even")
    let even = await eventually { session.visibleCount == 5 && session.selection.row(at: 0) == 0 }
    XCTAssertTrue(even)
    await settled(session)
    XCTAssertEqual(currentRow(session), 4, "the next row of the file after 7 is 8")
  }

  /// Catches a place kept by position in the rows shown, which a sort moves. Sorting descending
  /// leaves the current match on the same row of the file, now shown sixth.
  func testASortKeepsTheCurrentRowOfTheFile() async throws {
    let session = try await loadedSession(try Scratch(self), evenOdd)

    session.setFind("ab")
    await settled(session)
    stepTo(session, index: 3)

    session.setSort(SortSpec(column: .named("id"), ascending: false))
    let sorted = await eventually { session.selection != .all(count: 10) }
    XCTAssertTrue(sorted)
    await settled(session)
    XCTAssertEqual(currentRow(session), 6, "row 3 of the file is shown sixth, after 9 down to 4")
  }

  /// Catches a new query that starts where an old, unrelated one stood. A query with no matches, a
  /// cleared bar, and a new word start from the first match.
  func testAnUnrelatedQueryStartsAtTheFirstMatch() async throws {
    let session = try await loadedSession(try Scratch(self), evenOdd)

    session.setFind("ab")
    await settled(session)
    stepTo(session, index: 5)

    session.setFind("zzz")
    await settled(session)
    XCTAssertTrue(session.matches.isEmpty)

    session.setFind("")
    session.setFind("ab")
    await settled(session)
    XCTAssertEqual(currentRow(session), 0)
  }

  /// Catches a scroll request on every reload of rows. The revision a view scrolls on moves for a
  /// new query and for a step. It stays put when a filter reloads the rows, so a user scrolling
  /// while rows change is not pulled back.
  func testOnlyAQueryOrAStepAsksTheViewToScroll() async throws {
    let session = try await loadedSession(try Scratch(self), evenOdd)

    session.setFind("ab")
    await settled(session)
    let afterQuery = session.matchRevision
    XCTAssertGreaterThan(afterQuery, 0)

    session.setFilter("odd")
    let odd = await eventually { session.visibleCount == 5 }
    XCTAssertTrue(odd)
    await settled(session)
    XCTAssertEqual(session.matchRevision, afterQuery)

    session.stepMatch(forward: true)
    XCTAssertEqual(session.matchRevision, afterQuery + 1)
  }
}
