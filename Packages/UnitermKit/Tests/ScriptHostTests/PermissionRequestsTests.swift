import XCTest

@testable import ScriptHost

/// The permission store alone, apart from any program or panel.
@MainActor
final class PermissionRequestsTests: XCTestCase {
  /// Catches a denial that lapses because the user denied other things after it. A denial holds
  /// until the user chooses Ask Again or its requester ends, however many follow it, so a denied
  /// program is never asked again on its own.
  func testADenialHoldsHoweverManyDenialsFollowIt() {
    let requests = PermissionRequests()
    let first = key(0)

    requests.recordDenial(first, subject: "synthetic 0", title: "Read the clipboard")

    for index in 1...100 {
      requests.recordDenial(key(index), subject: "synthetic \(index)", title: "Read the clipboard")
    }

    XCTAssertTrue(requests.isDenied(first))

    let outcome = requests.ask(
      first, subject: "synthetic 0", title: "Read the clipboard", detail: "synthetic",
      sessionTitle: "Allow for This Run"
    ) { _ in XCTFail("a denied request was answered") }

    XCTAssertEqual(outcome, .denied)
    XCTAssertTrue(requests.rows.isEmpty, "a denied request opened a row")
  }

  /// Catches a once-only row that a session answer can widen. The panel hides the session button,
  /// and the store answers a session answer as Allow once, so only the oldest waiting operation is
  /// released and the requester learns no session was granted.
  func testAOnceOnlyRowAnswersASessionAnswerAsAllowOnce() {
    let requests = PermissionRequests()
    var answers: [PermissionRequests.Answer] = []

    for index in 0..<2 {
      let outcome = requests.ask(
        key(1), subject: "synthetic", title: "Open a file", detail: "request \(index)",
        sessionTitle: "Allow for This Session", onceOnly: true
      ) { answers.append($0) }

      XCTAssertEqual(outcome, .waiting)
    }

    let row = requests.rows[0]

    XCTAssertTrue(row.onceOnly)

    requests.decide(row.id, .allowForSession)

    XCTAssertEqual(answers, [.allowOnce])
    XCTAssertEqual(requests.rows.first?.detail, "request 1")
  }

  /// Catches a flood of once-only open events that fills every row and leaves no room for another
  /// requester. Each event is its own requester, so the events bound together as one. Past the
  /// bound the new event is refused as busy, the waiting rows stay, and another requester still
  /// gets its question.
  func testAFloodOfOneEventRequestersLeavesRoomForAnotherRequester() {
    let requests = PermissionRequests()
    var outcomes: [PermissionRequests.Outcome] = []

    for index in 0..<(PermissionRequests.maxRows + 20) {
      outcomes.append(
        requests.ask(
          PermissionRequests.Key(requester: .launchEvent(UInt64(index)), power: "open files"),
          subject: "synthetic", title: "Open a file", detail: "event \(index)",
          sessionTitle: "Allow", onceOnly: true
        ) { _ in })
    }

    XCTAssertEqual(
      outcomes.filter { $0 == .waiting }.count, PermissionRequests.maxRowsPerRequester)
    XCTAssertEqual(outcomes.last, .busy)
    XCTAssertEqual(requests.rows.count, PermissionRequests.maxRowsPerRequester)
    XCTAssertEqual(requests.rows.first?.detail, "event 0", "a waiting row was dropped")

    let other = requests.ask(
      key(1), subject: "synthetic", title: "Read the clipboard", detail: "synthetic",
      sessionTitle: "Allow for This Run"
    ) { _ in }

    XCTAssertEqual(other, .waiting)
  }

  private func key(_ index: Int) -> PermissionRequests.Key {
    PermissionRequests.Key(requester: .connection(UInt64(index)), power: "clipboard-read")
  }
}
