import AppKit
import AppletKit
import PaneModel
import StatusKit
import XCTest

@testable import WindowKit

/// The history panel, the host-bound origin of pane messages, and the unseen signal as the panel
/// drives it. Every test runs the real controller, bar, and panel over the injected clock.
@MainActor
final class HistoryPanelTests: XCTestCase {
  private var fixtures: [WindowFixture] = []

  override func tearDown() async throws {
    for fixture in fixtures {
      fixture.cleanUp()
    }

    fixtures = []
  }

  private func makeFixture() throws -> WindowFixture {
    let fixture = try WindowFixture()
    fixtures.append(fixture)
    return fixture
  }

  private func panel(_ fixture: WindowFixture) -> HistoryPanelView {
    fixture.controller.contentController.history
  }

  private func open(_ fixture: WindowFixture) {
    fixture.controller.dispatch(.toggleMessageHistory)
    fixture.layout()
  }

  // MARK: Origin identity

  /// Catches a pane message that takes its identity from the applet a caller names. The host is
  /// bound to pane 2's applet, so a post that names pane 1's applet is still pane 2's.
  func testAHostPostsOnlyAsItsOwnPane() throws {
    let fixture = try makeFixture()
    fixture.controller.openPane(.terminalShell, axis: .row)
    let (one, two) = (fixture.log.made[0], fixture.log.made[1])

    two.host?.applet(one, post: .info, text: "claimed")

    XCTAssertEqual(fixture.center.history.last?.source.paneID, 2)
  }

  /// Catches a launcher swap that gives the new applet a different identity than the pane's.
  func testALauncherSwapKeepsThePaneIdentity() throws {
    let fixture = try makeFixture()
    let pane = try XCTUnwrap(fixture.controller.openLauncher(axis: .row))
    let launcher = try XCTUnwrap(fixture.controller.paneArea.applet(for: pane) as? LauncherApplet)

    try launcher.onChoose?(.terminalShell)
    fixture.log.made.last?.say(.info, "after the swap")

    XCTAssertEqual(fixture.center.history.last?.source.paneID, pane.rawValue)
  }

  /// Catches a closed pane's recorded message that loses its identity, and two panes with one title
  /// that share one. The first applet posts after its pane closed.
  func testClosedPanesKeepDistinctIdentitiesDespiteEqualTitles() throws {
    let fixture = try makeFixture()
    fixture.controller.openPane(.terminalShell, axis: .row)
    let (one, two) = (fixture.log.made[0], fixture.log.made[1])
    one.title = "same"
    two.title = "same"

    one.say(.warning, "from one")
    two.say(.warning, "from two")
    fixture.controller.dispatch(.close)
    two.note(.info, "late record")

    let ids = fixture.center.history.map { $0.source.paneID }
    XCTAssertEqual(ids, [1, 2, 2])
  }

  // MARK: Filter

  /// Catches a filter that keys on the title, a host record that joins a pane, and a closed pane
  /// that loses its rows or its mark.
  func testTheFilterListsPanesByIDAndKeepsClosedPanes() throws {
    let fixture = try makeFixture()
    fixture.controller.openPane(.terminalShell, axis: .row)
    let (one, two) = (fixture.log.made[0], fixture.log.made[1])
    one.title = "same"
    two.title = "same"

    one.say(.info, "a")
    two.say(.info, "b")
    fixture.center.post(level: .info, text: "host")
    open(fixture)

    let panel = panel(fixture)
    XCTAssertEqual(panel.filterTitles, ["All", "same (pane 1)", "same (pane 2)"])
    XCTAssertEqual(panel.lines.count, 3)

    panel.select(.pane(2))
    XCTAssertEqual(panel.lines, ["info  same (pane 2): b"])

    fixture.controller.dispatch(.close)
    fixture.center.post(level: .info, text: "later host")
    XCTAssertEqual(panel.filterTitles, ["All", "same (pane 1)", "same (pane 2), closed"])
    XCTAssertEqual(panel.lines, ["info  same (pane 2): b"])

    panel.select(.all)
    XCTAssertEqual(panel.lines.count, 4)
  }

  // MARK: Unseen

  /// Catches an unseen signal cleared by merely opening the panel. Sixty errors do not fit in the
  /// viewport, so only the rows in view are acknowledged.
  func testOpeningThePanelAcknowledgesOnlyTheRowsInView() throws {
    let fixture = try makeFixture()

    for index in 0..<60 {
      fixture.center.post(level: .error, text: "e\(index)")
    }

    open(fixture)

    let exposed = panel(fixture).exposedIDs.count
    XCTAssertGreaterThan(exposed, 0)
    XCTAssertLessThan(exposed, 20)
    XCTAssertEqual(fixture.center.queue.unseenErrorCount, 60 - exposed)
    XCTAssertTrue(fixture.center.hasUnseenError)
  }

  /// Catches scrolling that does not acknowledge what it brings into view.
  func testScrollingAcknowledgesTheRowsItExposes() throws {
    let fixture = try makeFixture()

    for index in 0..<60 {
      fixture.center.post(level: .error, text: "e\(index)")
    }

    open(fixture)
    let panel = panel(fixture)
    let before = fixture.center.queue.unseenErrorCount

    let clip = panel.scrollView.contentView
    clip.scroll(to: NSPoint(x: 0, y: 30 * HistoryPanelView.rowHeight))
    panel.scrollView.reflectScrolledClipView(clip)

    XCTAssertLessThan(fixture.center.queue.unseenErrorCount, before)
  }

  /// Catches a later arrival that is acknowledged although the user scrolled away from the top.
  func testAnArrivalOutsideTheViewportStaysUnseen() throws {
    let fixture = try makeFixture()

    for index in 0..<60 {
      fixture.center.post(level: .error, text: "e\(index)")
    }

    open(fixture)
    let panel = panel(fixture)
    let clip = panel.scrollView.contentView
    clip.scroll(to: NSPoint(x: 0, y: 30 * HistoryPanelView.rowHeight))
    panel.scrollView.reflectScrolledClipView(clip)

    fixture.center.post(level: .error, text: "late")

    let late = try XCTUnwrap(fixture.center.history.last)
    XCTAssertTrue(fixture.center.queue.unseenIDs.contains(late.id))
  }

  /// Catches a row that a filter hides but the panel acknowledges anyway. Pane 2's error arrives
  /// while the filter shows pane 1 only.
  func testAFilteredOutMessageStaysUnseenWhileThePanelIsOpen() throws {
    let fixture = try makeFixture()
    fixture.controller.openPane(.terminalShell, axis: .row)
    let (one, two) = (fixture.log.made[0], fixture.log.made[1])
    one.say(.info, "a")
    open(fixture)
    panel(fixture).select(.pane(1))

    two.say(.error, "hidden")
    XCTAssertTrue(fixture.center.hasUnseenError)

    panel(fixture).select(.all)
    XCTAssertFalse(fixture.center.hasUnseenError, "it was in view after the filter cleared")
  }

  /// Catches an error that raises the signal while the panel shows the top of the list.
  func testAnErrorInViewAtTheTopIsAcknowledgedOnArrival() throws {
    let fixture = try makeFixture()
    open(fixture)

    fixture.center.post(level: .error, text: "late")

    XCTAssertFalse(fixture.center.hasUnseenError)
    XCTAssertEqual(panel(fixture).lines, ["error  uniterm: late"])
  }

  /// Catches an indicator that shows no lesser tone for warnings, or that shows both at once.
  func testTheBarShowsTheUnseenWarningOnlyWhenNoErrorIsUnseen() throws {
    let fixture = try makeFixture()

    fixture.center.post(level: .warning, text: "w")
    XCTAssertTrue(fixture.bar.segments.contains { $0.id == .unseenWarning })
    XCTAssertFalse(fixture.bar.segments.contains { $0.id == .unseenError })
    XCTAssertEqual(fixture.bar.segments.first { $0.id == .unseenWarning }?.tone, .warning)

    fixture.center.post(level: .error, text: "E")
    XCTAssertTrue(fixture.bar.segments.contains { $0.id == .unseenError })
    XCTAssertFalse(fixture.bar.segments.contains { $0.id == .unseenWarning })
  }

  // MARK: Loss

  /// Catches a retention loss with no readable summary, or one that cannot be cleared. 101 errors
  /// from one pane drop one, and the summary acknowledges its unseen count only when asked.
  func testTheLossSummaryIsReadableAndAcknowledgedDeliberately() throws {
    let fixture = try makeFixture()

    for index in 0..<101 {
      fixture.center.post(level: .error, text: "e\(index)")
    }

    open(fixture)
    let panel = panel(fixture)

    XCTAssertTrue(panel.lossText.contains("dropped 1 error"), panel.lossText)
    XCTAssertEqual(panel.lossLabelAccessibilityValue, panel.lossText)
    XCTAssertEqual(panel.lossLabelToolTip, panel.lossText)
    XCTAssertTrue(panel.lossAcknowledgeButton.isEnabled)

    // Most of the 100 retained rows are out of view and stay unseen. The lost error's own count
    // is cleared only by the summary's control.
    XCTAssertEqual(fixture.center.queue.loss.unseenErrors, 1)

    panel.lossAcknowledgeButton.performClick(nil)
    XCTAssertEqual(fixture.center.queue.loss.unseenErrors, 0)
    XCTAssertEqual(fixture.center.queue.loss.errors, 1)
    XCTAssertFalse(panel.lossAcknowledgeButton.isEnabled)
  }

  // MARK: Full text

  /// Catches a long message whose full text is unreachable: the row keeps it in its value and its
  /// tooltip, though it draws one truncated line.
  func testAnyRetainedMessageHasItsFullTextInItsRow() throws {
    let fixture = try makeFixture()
    let text = String(repeating: "word ", count: 300)
    fixture.center.post(level: .warning, text: text)
    open(fixture)

    let label = try XCTUnwrap(panel(fixture).rowLabel(at: 0))
    let bounded = StatusText.bounded(text, maximumBytes: StatusPolicy.standard.maximumTextBytes)

    XCTAssertEqual(label.stringValue, "warning  uniterm: \(bounded)")
    XCTAssertEqual(label.toolTip, label.stringValue)
    XCTAssertEqual(label.accessibilityValue(), label.stringValue)
    XCTAssertEqual(label.maximumNumberOfLines, 1)
  }

  /// Catches an acknowledgement that runs inside the panel's own layout pass. It refreshes the
  /// rows, which lays the panel out again from inside layout, and AppKit forbids that.
  func testExposureIsNeverReportedFromInsideLayout() async throws {
    let fixture = try makeFixture()
    fixture.center.post(level: .error, text: "e")
    open(fixture)

    let panel = panel(fixture)
    var duringLayout: [Bool] = []
    panel.onExposed = { [unowned panel] _ in duringLayout.append(panel.isLayingOut) }

    panel.needsLayout = true
    panel.layoutSubtreeIfNeeded()
    await Task.yield()
    await Task.yield()

    XCTAssertFalse(duringLayout.contains(true))
    XCTAssertFalse(duringLayout.isEmpty, "the exposure was never reported")
  }

  /// Catches rows whose full text is reachable for only the first one. Three long messages each
  /// keep their whole text in the row value, the tooltip, and the accessibility value.
  func testEveryRowKeepsItsFullTextForAssistiveTechnology() throws {
    let fixture = try makeFixture()
    let texts = (0..<3).map { "message \($0) " + String(repeating: "word ", count: 120) }

    for text in texts {
      fixture.center.post(level: .info, text: text)
    }

    open(fixture)
    let panel = panel(fixture)

    for index in 0..<3 {
      let label = try XCTUnwrap(panel.rowLabel(at: index))
      let expected = "info  uniterm: \(StatusText.bounded(texts[2 - index], maximumBytes: 2048))"

      XCTAssertEqual(label.stringValue, expected)
      XCTAssertEqual(label.toolTip, expected)
      XCTAssertEqual(label.accessibilityValue(), expected)
    }
  }

  // MARK: Keyboard

  /// Catches a panel that takes the keyboard when it opens or when it is read, and one the
  /// keyboard can never reach. Opening and selecting change nothing. The command then moves the
  /// keyboard into the table, and Escape returns it to the pane.
  func testTheKeyboardEntersOnlyOnRequestAndEscapeReturnsIt() throws {
    let fixture = try makeFixture()
    fixture.controller.openPane(.terminalShell, axis: .row)
    fixture.log.made[1].say(.info, "from two")
    let window = try XCTUnwrap(fixture.controller.window)
    let before = window.firstResponder

    open(fixture)
    let panel = panel(fixture)
    panel.select(.pane(2))
    panel.select(.all)
    XCTAssertTrue(window.firstResponder === before, "reading moved the keyboard")

    fixture.controller.dispatch(.focusMessageHistory)
    XCTAssertTrue(panel.isKeyboardEngaged)
    XCTAssertTrue(window.firstResponder is HistoryTableView)

    panel.releaseKeyboard()
    XCTAssertFalse(panel.isKeyboardEngaged)
    XCTAssertFalse(window.firstResponder is HistoryTableView)
  }

  /// Catches a row cursor that cannot run Focus Pane. Return on the newest row, which came from
  /// pane 2, focuses pane 2 and gives the keyboard back.
  func testReturnOnARowFocusesItsPaneAndReleasesTheKeyboard() throws {
    let fixture = try makeFixture()
    fixture.controller.openPane(.terminalShell, axis: .row)
    fixture.controller.dispatch(.focusPaneLeft)
    fixture.log.made[1].say(.info, "from two")
    XCTAssertEqual(fixture.controller.focusedPane, NodeID(rawValue: 1))

    fixture.controller.dispatch(.focusMessageHistory)
    let panel = panel(fixture)
    XCTAssertTrue(panel.isKeyboardEngaged)

    panel.activateSelectedRow()

    XCTAssertEqual(fixture.controller.focusedPane, NodeID(rawValue: 2))
    XCTAssertFalse(panel.isKeyboardEngaged)
  }

  /// Catches a key loop that leaves the panel out: the table, the filter, and the loss control
  /// when it shows.
  func testTabReachesTheFilterAndTheLossControl() throws {
    let fixture = try makeFixture()

    for index in 0..<101 {
      fixture.center.post(level: .error, text: "e\(index)")
    }

    fixture.controller.dispatch(.focusMessageHistory)
    let panel = panel(fixture)

    let loop = panel.keyLoop
    XCTAssertEqual(loop.count, 3)
    XCTAssertTrue(loop[1] === panel.filterControl)
    XCTAssertTrue(loop[2] === panel.lossAcknowledgeButton)
  }

  // MARK: Exposure

  /// Catches a row with a sliver in view that counts as read. The newest row scrolls half out of
  /// the top, and it is not acknowledged.
  func testARowWithASliverInViewIsNotExposed() throws {
    let fixture = try makeFixture()

    for index in 0..<40 {
      fixture.center.post(level: .error, text: "e\(index)")
    }

    open(fixture)
    let panel = panel(fixture)
    let clip = panel.scrollView.contentView
    clip.scroll(to: NSPoint(x: 0, y: HistoryPanelView.rowHeight / 2))
    panel.scrollView.reflectScrolledClipView(clip)

    let newest = try XCTUnwrap(fixture.center.history.last).id

    XCTAssertFalse(panel.exposedIDs.contains(newest))
  }

  /// Catches a panel in a minimized or covered window that acknowledges what arrives. Nothing is
  /// acknowledged while the window shows nothing, and the rows count as read once it does.
  func testNothingIsAcknowledgedWhileTheWindowShowsNothing() throws {
    let fixture = try makeFixture()
    fixture.controller.windowShowsContentOverride = { false }
    open(fixture)

    fixture.center.post(level: .error, text: "unseen while hidden")
    fixture.layout()

    XCTAssertTrue(fixture.center.hasUnseenError)

    fixture.controller.windowShowsContentOverride = { true }
    panel(fixture).reportExposure()

    XCTAssertFalse(fixture.center.hasUnseenError)
  }

  // MARK: Focus Pane

  /// Catches reading that moves focus, and a Focus Pane control that does not reach its pane.
  func testFocusPaneMovesFocusOnlyOnActivation() throws {
    let fixture = try makeFixture()
    fixture.controller.openPane(.terminalShell, axis: .row)
    fixture.controller.dispatch(.focusPaneLeft)
    XCTAssertEqual(fixture.controller.focusedPane, NodeID(rawValue: 1))

    fixture.log.made[1].say(.info, "from two")
    open(fixture)

    let panel = panel(fixture)
    _ = panel.rowLabel(at: 0)
    panel.select(.pane(2))
    panel.select(.all)
    XCTAssertEqual(fixture.controller.focusedPane, NodeID(rawValue: 1), "reading moved focus")

    let record = try XCTUnwrap(fixture.center.history.last)
    let button = try XCTUnwrap(panel.focusButton(forRecord: record.id))
    XCTAssertTrue(button.isEnabled)

    button.performClick(nil)

    XCTAssertEqual(fixture.controller.focusedPane, NodeID(rawValue: 2))
  }

  /// Catches a stale ID that is acted on. The pane closes after the row drew its enabled control.
  /// Activation resolves the ID again, so nothing is focused, reopened, or targeted.
  func testAPaneClosedBeforeActivationIsNeverReopenedOrTargeted() throws {
    let fixture = try makeFixture()
    fixture.controller.openPane(.terminalShell, axis: .row)
    fixture.log.made[1].say(.info, "from two")
    open(fixture)

    let panel = panel(fixture)
    let record = try XCTUnwrap(fixture.center.history.last)
    let button = try XCTUnwrap(panel.focusButton(forRecord: record.id))
    XCTAssertTrue(button.isEnabled)

    fixture.controller.dispatch(.close)
    let entries = fixture.controller.ledger.entries.count
    let made = fixture.log.made.count
    XCTAssertEqual(fixture.controller.paneIDs, [NodeID(rawValue: 1)])

    button.performClick(nil)

    XCTAssertEqual(fixture.controller.paneIDs, [NodeID(rawValue: 1)])
    XCTAssertEqual(fixture.controller.focusedPane, NodeID(rawValue: 1))
    XCTAssertEqual(fixture.controller.ledger.entries.count, entries)
    XCTAssertEqual(fixture.log.made.count, made)
    XCTAssertFalse(try XCTUnwrap(panel.focusButton(forRecord: record.id)).isEnabled)
  }

  /// Catches a reopened pane that inherits an old row. Undo reopen allocates a new ID, so the old
  /// row stays closed.
  func testAReopenedPaneDoesNotReviveOldRows() throws {
    let fixture = try makeFixture()
    fixture.controller.openPane(.terminalShell, axis: .row)
    fixture.log.made[1].say(.info, "from two")
    fixture.controller.dispatch(.close)
    fixture.controller.reopenClosed()
    open(fixture)

    XCTAssertFalse(fixture.controller.contains(pane: NodeID(rawValue: 2)))
    XCTAssertFalse(fixture.controller.focusPaneFromHistory(2))
  }

  // MARK: Cost

  /// Checks the panel at its full 500 rows through the real window. Only the rows in view build a
  /// cell, so the cost of a refresh does not grow with the history.
  func testAFullHistoryBuildsOnlyTheRowsInView() throws {
    let fixture = try makeFixture()

    for index in 0..<400 {
      fixture.center.post(level: .info, text: "m\(index)")
    }

    for index in 0..<100 {
      fixture.center.post(level: .error, text: "e\(index)")
    }

    open(fixture)
    let panel = panel(fixture)

    fixture.center.post(level: .info, text: "one more")
    fixture.layout()

    XCTAssertEqual(panel.lines.count, 500)
    XCTAssertLessThan(panel.builtCellCount, 40)
    XCTAssertEqual(panel.frame.height, HistoryPanelView.height)
  }
}
