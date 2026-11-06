import AppKit
import AppletKit
import PaneModel
import XCTest

@testable import WindowKit

/// Reopen Closed over fake applets that keep closed-tab lists as a terminal does. The window owns
/// the stamps and the walk. The applets own their lists and report success or failure.
@MainActor
final class ReopenClosedTests: XCTestCase {
  private var fixtures: [UndoFixture] = []

  override func tearDown() async throws {
    for fixture in fixtures {
      fixture.cleanUp()
    }

    fixtures = []
  }

  private func makeFixture() throws -> UndoFixture {
    let fixture = try UndoFixture()
    fixtures.append(fixture)
    return fixture
  }

  private func id(_ value: UInt64) -> NodeID { NodeID(rawValue: value) }

  private func close(_ fixture: UndoFixture, pane: UInt64) {
    fixture.controller.paneArea.focus(id(pane))
    fixture.controller.dispatch(.close)
  }

  private func burnStamps(_ fixture: UndoFixture, _ count: Int) {
    for _ in 0..<count { _ = fixture.controller.issueCloseStamp() }
  }

  private func lastMessage(_ fixture: UndoFixture) -> String? {
    fixture.controller.statusCenter.history.last?.text
  }

  private func shrink(_ fixture: UndoFixture) throws {
    let window = try XCTUnwrap(fixture.controller.window)
    window.setContentSize(NSSize(width: 300, height: 640))
    window.contentView?.layoutSubtreeIfNeeded()
  }

  // MARK: Ordering

  /// Catches a walk that orders by pane or by applet instead of by close. Tab closes at stamps 3 and
  /// 6 sit in one pane, and a pane close sits at 4. The tab at 6 fails to reopen, so the same press
  /// reopens the pane at 4. The failed tab keeps its place, the tab at 3 is untouched, and one
  /// message names the failure and what reopened instead.
  func testAFailedNewestTabFallsBackToThePaneBetweenTwoTabs() throws {
    let fixture = try makeFixture()
    fixture.openPanes(2)
    fixture.made[0].tabCount = 4

    burnStamps(fixture, 2)
    close(fixture, pane: 1)
    close(fixture, pane: 2)
    burnStamps(fixture, 1)
    close(fixture, pane: 1)

    XCTAssertEqual(fixture.made[0].closedTabStamps, [6, 3])
    XCTAssertEqual(fixture.controller.ledger.entries.map(\.stamp), [4])

    fixture.made[0].failingReopens = [6]
    fixture.controller.reopenClosed()

    XCTAssertEqual(fixture.recorder.restored.map(\.title), ["Fake 1"])
    XCTAssertTrue(fixture.controller.ledger.entries.isEmpty)
    XCTAssertEqual(fixture.made[0].closedTabStamps, [6, 3])
    XCTAssertTrue(fixture.made[0].reopened.isEmpty)
    XCTAssertEqual(
      lastMessage(fixture),
      "The tab \u{201C}Fake 0 tab 1\u{201D} could not be reopened: the session did not start. "
        + "Reopened the pane \u{201C}Fake 1\u{201D} instead.")
  }

  /// Catches an older pane that reopens past a failed newer close and takes the wrong entry with
  /// it. Panes 4 and 2 close at stamps 1 and 2, and a tab at 3 fails. The press reopens pane 2's
  /// entry and leaves pane 4's.
  func testReopeningAnOlderPanePastAFailedCloseRemovesOnlyThatEntry() throws {
    let fixture = try makeFixture()
    fixture.openPanes(3)
    fixture.made[0].tabCount = 2

    close(fixture, pane: 4)
    close(fixture, pane: 2)
    close(fixture, pane: 1)
    fixture.made[0].failingReopens = [3]

    fixture.controller.reopenClosed()

    XCTAssertEqual(fixture.recorder.restored.map(\.title), ["Fake 1"])
    XCTAssertEqual(fixture.controller.ledger.entries.map(\.stamp), [1])
    XCTAssertEqual(fixture.made[0].closedTabStamps, [3])
  }

  /// Catches a pane that is too large to fit blocking the tab closed after it. Pane 2 closes, then
  /// the window shrinks, then a tab closes. The first press reopens the tab and leaves the pane
  /// with no message. The second press cannot fit the pane, keeps it, and says so.
  func testATabClosedAfterAnUnfittablePaneReopensAndThePaneStays() throws {
    let fixture = try makeFixture()
    fixture.openPanes(2)
    fixture.made[0].tabCount = 2
    close(fixture, pane: 2)
    close(fixture, pane: 1)
    try shrink(fixture)
    let messages = fixture.controller.statusCenter.history.count

    fixture.controller.reopenClosed()

    XCTAssertEqual(fixture.made[0].reopened, [2])
    XCTAssertEqual(fixture.controller.ledger.entries.count, 1)
    XCTAssertEqual(fixture.controller.statusCenter.history.count, messages)

    fixture.controller.reopenClosed()

    XCTAssertEqual(fixture.controller.paneIDs, [id(1)])
    XCTAssertEqual(fixture.controller.ledger.entries.count, 1)
    XCTAssertTrue(fixture.recorder.restored.isEmpty, "the applet was built before the fit check")
    XCTAssertEqual(
      lastMessage(fixture),
      "The pane \u{201C}Fake 1\u{201D} does not fit in the window. "
        + "Make the window larger, then try again. Nothing was reopened.")
  }

  /// Catches a failed tab that moves focus or selection, or eats its entry, when nothing else
  /// reopens. The message says nothing reopened, and the entry keeps its stamp.
  func testWhenEveryCloseFailsNothingChangesAndTheMessageSaysSo() throws {
    let fixture = try makeFixture()
    fixture.openPanes(2)
    fixture.made[0].tabCount = 3
    fixture.made[0].selectedTabIndex = 1
    fixture.controller.paneArea.focus(id(1))
    fixture.controller.dispatch(.close)
    fixture.made[0].failingReopens = [1]
    let tabs = fixture.made[0].publishedTabs

    fixture.controller.reopenClosed()

    XCTAssertEqual(fixture.controller.focusedPane, id(1))
    XCTAssertEqual(fixture.made[0].publishedTabs, tabs)
    XCTAssertEqual(fixture.made[0].closedTabStamps, [1])
    XCTAssertEqual(
      lastMessage(fixture),
      "The tab \u{201C}Fake 0 tab 2\u{201D} could not be reopened: the session did not start. "
        + "Nothing was reopened.")
  }

  /// Catches a focused-pane rule. A tab closes in pane 1, then pane 2 closes, and pane 1 has focus.
  /// The newest close is the pane, so the first press brings it back. The tab is next.
  func testAPaneClosedAfterATabInAnotherPaneComesBackFirst() throws {
    let fixture = try makeFixture()
    fixture.openPanes(2)
    fixture.made[0].tabCount = 2
    close(fixture, pane: 1)
    close(fixture, pane: 2)
    XCTAssertEqual(fixture.controller.focusedPane, id(1))

    fixture.controller.reopenClosed()

    XCTAssertEqual(fixture.controller.paneIDs.count, 2)
    XCTAssertTrue(fixture.made[0].reopened.isEmpty)

    fixture.controller.reopenClosed()

    XCTAssertEqual(fixture.made[0].reopened, [1])
    XCTAssertEqual(fixture.controller.focusedPane, id(1))
  }

  /// Catches a pane undo that drops the pane's closed tabs. Tab B closes, then its pane. The first
  /// press brings the pane back, and the second brings the tab back into it and focuses it.
  func testTwoPressesBringBackAPaneAndThenItsClosedTab() throws {
    let fixture = try makeFixture()
    fixture.openPanes(2)
    fixture.made[1].tabCount = 2
    close(fixture, pane: 2)
    fixture.controller.dispatch(.close)
    XCTAssertEqual(fixture.controller.paneIDs, [id(1)])

    fixture.controller.reopenClosed()

    let reopened = try XCTUnwrap(fixture.recorder.restored.first)
    XCTAssertEqual(reopened.closedTabStamps, [1])
    XCTAssertEqual(fixture.controller.paneIDs.count, 2)

    fixture.controller.paneArea.focus(id(1))
    fixture.controller.reopenClosed()

    XCTAssertEqual(reopened.reopened, [1])
    XCTAssertEqual(fixture.controller.focusedPane, fixture.controller.paneIDs[1])
  }

  /// Catches a reopened pane whose old stamps are renumbered. The pane returns with a tab closed at
  /// stamp 1. A tab closed since in pane 1 has stamp 3 and comes first, then the carried one.
  func testACarriedStampSortsAgainstClosesMadeSince() throws {
    let fixture = try makeFixture()
    fixture.openPanes(2)
    fixture.made[0].tabCount = 2
    fixture.made[1].tabCount = 2
    close(fixture, pane: 2)
    fixture.controller.dispatch(.close)
    fixture.controller.reopenClosed()
    let reopened = try XCTUnwrap(fixture.recorder.restored.first)

    close(fixture, pane: 1)
    XCTAssertEqual(fixture.made[0].closedTabStamps, [3])

    fixture.controller.reopenClosed()
    XCTAssertEqual(fixture.made[0].reopened, [3])
    XCTAssertTrue(reopened.reopened.isEmpty)

    fixture.controller.reopenClosed()
    XCTAssertEqual(reopened.reopened, [1])
  }

  // MARK: Layout

  /// Catches a closed-tab list that reaches the saved layout or counts as a layout change. A tab
  /// closes in the applet. The saved description holds no undo part, and the change alone does not
  /// ask for a save. A title change, which the payload holds, still does.
  func testTheClosedTabListIsNotPartOfTheSavedLayout() throws {
    let fixture = try makeFixture()
    var layoutChanges = 0
    fixture.controller.onLayoutChange = { layoutChanges += 1 }
    _ = fixture.controller.savedWindow()

    fixture.made[0].closedTabs = [FakeApplet.ClosedTab(stamp: 1, title: "t")]
    fixture.controller.appletDidChange(fixture.made[0])

    XCTAssertEqual(layoutChanges, 0)

    let saved = try XCTUnwrap(fixture.controller.savedWindow())

    guard case .pane(id: _, applet: let description) = saved.tree else {
      return XCTFail("not a pane")
    }

    XCTAssertNil(description.undoState)

    fixture.made[0].title = "Renamed"
    fixture.controller.appletDidChange(fixture.made[0])

    XCTAssertEqual(layoutChanges, 1)
  }

  // MARK: Command

  /// Catches a Reopen item that stays on with nothing to reopen, which would let the reserved key
  /// fall through to the view. The item is off with nothing closed and on after a pane closes. It
  /// holds Cmd-Shift-T in File under a fixed title.
  func testTheReopenItemFollowsWhetherAnythingIsClosed() throws {
    let fixture = try makeFixture()
    fixture.openPanes(2)
    let harness = MenuHarness(fixture.controller)
    let item = try XCTUnwrap(harness.item(.reopenClosed))

    XCTAssertEqual(item.title, "Reopen Closed Tab or Pane")
    XCTAssertEqual(item.menu?.title, "File")
    XCTAssertEqual(item.keyEquivalent, "t")
    XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .shift])
    XCTAssertFalse(harness.validate(.reopenClosed))

    fixture.controller.dispatch(.close)

    XCTAssertTrue(harness.validate(.reopenClosed))
    XCTAssertEqual(item.title, "Reopen Closed Tab or Pane")

    fixture.controller.dispatch(.reopenClosed)

    XCTAssertEqual(fixture.controller.paneIDs.count, 2)
    XCTAssertFalse(harness.validate(.reopenClosed))
  }
}
