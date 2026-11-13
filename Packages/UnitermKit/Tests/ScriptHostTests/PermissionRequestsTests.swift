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

  private func key(_ index: Int) -> PermissionRequests.Key {
    PermissionRequests.Key(requester: .connection(UInt64(index)), power: "clipboard-read")
  }
}
