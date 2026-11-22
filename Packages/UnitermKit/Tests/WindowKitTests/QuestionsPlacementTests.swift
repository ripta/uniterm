import AppKit
import AppletKit
import PaneModel
import QuestionForm
import QuestionsApplet
import ScriptHost
import ScriptWire
import XCTest

@testable import WindowKit

/// Where a script's form opens, and what the window shows while it waits, against real windows of
/// fake applets and a real Questions pane.
///
/// The calls arrive through the window side of the host API, as the host makes them. These prove
/// the split, the focus, the badge, the header after the asker closes, the owned-group layout
/// rules, and the tab cap. They cannot prove how the pane looks or where the keyboard goes in the
/// running app. `QuestionsUITests` drives that.
@MainActor
final class QuestionsPlacementTests: XCTestCase {
  private static let spec = #"{"items": [{"id": "ok", "text": "Sure?", "type": "boolean"}]}"#

  private func makeFixture() -> ScriptingFixture {
    let fixture = ScriptingFixture()
    addTeardownBlock { @MainActor in fixture.cleanUp() }
    return fixture
  }

  /// What a requester heard, in order.
  private final class Heard {
    var outcomes: [FormOutcome] = []
  }

  private func ask(
    _ fixture: ScriptingFixture, as key: String, from caller: ScriptCaller? = nil,
    heard: Heard = Heard()
  ) throws -> Heard {
    let who = caller ?? fixture.caller
    let spec = try FormSpecReader.decode(Data(Self.spec.utf8))

    try fixture.scripting.openForm(
      spec, requester: FormRequester(key: key, name: "Requester \(key)"), caller: who
    ) { heard.outcomes.append($0) }

    return heard
  }

  private func questions(in controller: MainWindowController) throws -> (
    pane: NodeID, applet: QuestionsApplet
  ) {
    try XCTUnwrap(controller.questionsPane())
  }

  // MARK: Placement

  /// Catches a form that opens nowhere, or in a pane that is not beside its asker. With no
  /// Questions pane in the window, one opens in a split beside the asker, and takes focus as a
  /// split the user makes does. The form's tab is selected.
  func testTheFirstFormSplitsBesideTheAskerAndTakesFocus() throws {
    let fixture = makeFixture()
    let (controller, pane) = try fixture.openWindow()
    let asker = NodeID(rawValue: pane.pane)

    XCTAssertNil(controller.questionsPane())

    let heard = try ask(fixture, as: "a")
    let found = try questions(in: controller)

    XCTAssertNotEqual(found.pane, asker)
    XCTAssertEqual(controller.paneArea.tree.paneIDs.count, 2)
    XCTAssertEqual(controller.paneArea.focusedPane, found.pane, "a split takes focus")
    XCTAssertEqual(found.applet.requesterKeys, ["a"])
    XCTAssertEqual(found.applet.selectedRequesterKey, "a")
    XCTAssertTrue(found.applet.hasOpenForm(forRequester: "a"))
    XCTAssertTrue(heard.outcomes.isEmpty)
  }

  /// Catches a second requester getting a pane of its own. The window's Questions pane takes every
  /// form, each requester in its own tab, and the new tab is selected and holds focus.
  func testAnotherRequestersFormJoinsTheSameQuestionsPane() throws {
    let fixture = makeFixture()
    let (controller, pane) = try fixture.openWindow()

    _ = try ask(fixture, as: "a")

    let first = try questions(in: controller)

    controller.paneArea.focus(NodeID(rawValue: pane.pane))

    _ = try ask(fixture, as: "b")

    let again = try questions(in: controller)

    XCTAssertEqual(again.pane, first.pane)
    XCTAssertEqual(controller.paneArea.tree.paneIDs.count, 2)
    XCTAssertEqual(again.applet.requesterKeys, ["a", "b"])
    XCTAssertEqual(again.applet.selectedRequesterKey, "b")
    XCTAssertEqual(controller.paneArea.focusedPane, first.pane, "a new tab takes focus")
  }

  /// Catches a busy refusal that changes the screen. A requester that asks again while its form is
  /// open is refused, and nothing opens or moves.
  func testASecondFormFromOneRequesterIsBusyAndChangesNothing() throws {
    let fixture = makeFixture()
    let (controller, _) = try fixture.openWindow()

    _ = try ask(fixture, as: "a")

    let panes = controller.paneArea.tree.paneIDs

    XCTAssertThrowsError(try ask(fixture, as: "a")) {
      XCTAssertEqual(($0 as? ScriptCallError)?.kind, .busy)
    }

    XCTAssertEqual(controller.paneArea.tree.paneIDs, panes)
    XCTAssertEqual(try questions(in: controller).applet.openFormCount, 1)
  }

  /// Catches a window with no room that opens a pane anyway, or leaves a half-made one. The form is
  /// refused, and the window holds the same panes.
  func testAWindowWithNoRoomRefusesTheFormAndChangesNothing() throws {
    let fixture = makeFixture()
    let (controller, pane) = try fixture.openWindow()

    controller.window?.setContentSize(NSSize(width: 60, height: 40))
    controller.window?.contentView?.layoutSubtreeIfNeeded()

    let before = controller.paneArea.tree.paneIDs

    XCTAssertThrowsError(try ask(fixture, as: "a")) {
      XCTAssertEqual(($0 as? ScriptCallError)?.kind, .refused)
    }

    XCTAssertEqual(controller.paneArea.tree.paneIDs, before)
    XCTAssertNil(controller.questionsPane())
    XCTAssertEqual(before, [NodeID(rawValue: pane.pane)])
  }

  // MARK: Badge

  /// Catches a badge that is missing, or one that names no Questions pane, or one that stays after
  /// the form resolves. The asker's pane shows it with a tooltip and an accessibility label that
  /// name the Questions pane. The form's end clears it.
  func testTheAskersPaneShowsABadgeUntilTheFormResolves() throws {
    let fixture = makeFixture()
    let (controller, pane) = try fixture.openWindow()
    let asker = NodeID(rawValue: pane.pane)
    let view = try XCTUnwrap(controller.paneArea.paneView(for: asker))

    XCTAssertTrue(view.askingBadge.isHidden)

    _ = try ask(fixture, as: "a")

    let found = try questions(in: controller)
    let named = "Pane \(found.pane.rawValue)"

    XCTAssertFalse(view.askingBadge.isHidden)
    XCTAssertEqual(view.askingMark, PaneAskingMark(questionsPane: named))
    XCTAssertTrue(
      view.askingBadge.toolTip?.contains(named) == true,
      "\(String(describing: view.askingBadge.toolTip))")
    XCTAssertTrue(view.askingBadge.accessibilityLabel()?.contains(named) == true)
    XCTAssertNil(
      try XCTUnwrap(controller.paneArea.paneView(for: found.pane)).askingMark,
      "the Questions pane is not an asker")

    controller.discardForm(requester: "a")

    XCTAssertTrue(view.askingBadge.isHidden)
    XCTAssertNil(view.askingMark)
  }

  /// Catches a badge that sits on top of the control badge, which would hide one or the other.
  func testTheAskingBadgeSitsBesideTheControlBadge() throws {
    let fixture = makeFixture()
    let (controller, pane) = try fixture.openWindow()
    let view = try XCTUnwrap(controller.paneArea.paneView(for: NodeID(rawValue: pane.pane)))

    _ = try ask(fixture, as: "a")

    controller.window?.contentView?.layoutSubtreeIfNeeded()
    view.layoutSubtreeIfNeeded()

    XCTAssertFalse(view.controlBadge.isHidden, "the first pane is remote-controlled")
    XCTAssertFalse(view.askingBadge.isHidden)
    XCTAssertFalse(view.controlBadge.frame.intersects(view.askingBadge.frame))
    XCTAssertLessThan(view.askingBadge.frame.maxX, view.controlBadge.frame.minX + 0.5)
  }

  // MARK: Closes

  /// Catches the header pointing at a pane that is gone, or at another one. The asker closes while
  /// its form is open. The header says the pane is gone, and the form stays open.
  func testTheHeaderSaysSoWhenTheAskerPaneCloses() throws {
    let fixture = makeFixture()
    let (controller, pane) = try fixture.openWindow()
    let asker = NodeID(rawValue: pane.pane)

    _ = try ask(fixture, as: "a")
    controller.paneArea.focus(asker)
    controller.closePane(asker, appletEnded: false)

    let found = try questions(in: controller)
    let expected = "Pane \(asker.rawValue) closed, so the pane that asked is gone"

    XCTAssertTrue(found.applet.hasOpenForm(forRequester: "a"))
    XCTAssertTrue(
      Self.text(in: found.applet.view, contains: expected), "no header says \(expected)")
  }

  /// Catches a pane close that leaves the asker waiting forever. The Questions pane closing
  /// dismisses every open form, and the badge goes with it.
  func testClosingTheQuestionsPaneDismissesItsForms() throws {
    let fixture = makeFixture()
    let (controller, pane) = try fixture.openWindow()
    let view = try XCTUnwrap(controller.paneArea.paneView(for: NodeID(rawValue: pane.pane)))
    let heard = try ask(fixture, as: "a")
    let found = try questions(in: controller)

    controller.closePane(found.pane, appletEnded: false)

    XCTAssertEqual(heard.outcomes, [.dismissed])
    XCTAssertNil(controller.questionsPane())
    XCTAssertNil(view.askingMark)
  }

  /// Catches an end that keeps the tab. A requester that ends loses its tab, and the last tab
  /// takes the pane with it, as a tab the user closes does.
  func testEndingARequesterClosesItsTabAndTheLastTabClosesThePane() throws {
    let fixture = makeFixture()
    let (controller, _) = try fixture.openWindow()
    let heard = try ask(fixture, as: "a")

    controller.endForm(requester: "a")

    XCTAssertEqual(heard.outcomes, [.ended])
    XCTAssertNil(controller.questionsPane())
    XCTAssertEqual(controller.paneArea.tree.paneIDs.count, 1)
  }

  /// Catches a discard that closes the tab. A discarded form ends, the tab stays and says so, and
  /// the requester's next form reuses it.
  func testADiscardKeepsTheTabAndTheNextFormReusesIt() throws {
    let fixture = makeFixture()
    let (controller, _) = try fixture.openWindow()
    let first = try ask(fixture, as: "a")

    controller.discardForm(requester: "a")

    XCTAssertEqual(first.outcomes, [.ended])

    let found = try questions(in: controller)

    XCTAssertEqual(found.applet.requesterKeys, ["a"])

    _ = try ask(fixture, as: "a")

    XCTAssertEqual(try questions(in: controller).applet.requesterKeys, ["a"])
    XCTAssertEqual(try questions(in: controller).applet.openFormCount, 1)
  }

  // MARK: Tab cap

  /// Catches a full pane of resolved tabs refusing a new requester, and a requester's own resolved
  /// tab giving way to its own next form. The pane's resolved tabs make room for each newcomer,
  /// and a requester that asks again reuses its tab.
  func testFillingTheCapWithResolvedTabsNeverRefusesANewRequester() throws {
    let fixture = makeFixture()
    let (controller, _) = try fixture.openWindow()
    let cap = QuestionsApplet.defaultCap

    for index in 0..<cap {
      _ = try ask(fixture, as: "r\(index)")
      controller.discardForm(requester: "r\(index)")
    }

    let full = try questions(in: controller)

    XCTAssertEqual(full.applet.tabCount, cap)
    XCTAssertEqual(full.applet.openFormCount, 0)

    _ = try ask(fixture, as: "newcomer")

    let after = try questions(in: controller)

    XCTAssertEqual(after.applet.tabCount, cap, "a resolved tab gave way")
    XCTAssertTrue(after.applet.requesterKeys.contains("newcomer"))
    XCTAssertTrue(after.applet.hasOpenForm(forRequester: "newcomer"))

    controller.discardForm(requester: "newcomer")

    let keys = try questions(in: controller).applet.requesterKeys

    _ = try ask(fixture, as: "newcomer")

    XCTAssertEqual(
      try questions(in: controller).applet.requesterKeys, keys, "its own tab is reused")
  }

  /// Catches a pane of open forms that takes one more. Every tab holds an open form, so a new
  /// requester is refused as busy and the pane is unchanged.
  func testAFormPastTheCapOfOpenFormsIsBusy() throws {
    let fixture = makeFixture()
    let (controller, _) = try fixture.openWindow()

    for index in 0..<QuestionsApplet.defaultCap { _ = try ask(fixture, as: "r\(index)") }

    XCTAssertThrowsError(try ask(fixture, as: "extra")) {
      XCTAssertEqual(($0 as? ScriptCallError)?.kind, .busy)
    }

    XCTAssertEqual(try questions(in: controller).applet.tabCount, QuestionsApplet.defaultCap)
  }

  // MARK: Owned groups

  private func presentation(_ source: NodeID) -> String {
    #"{"split":"row","children":[{"pane":\#(source.rawValue)},"#
      + #"{"open":"terminal","control":"remote-controlled"}]}"#
  }

  private func layOut(
    _ fixture: ScriptingFixture, _ layout: String, from anchor: NodeID, as who: ScriptCaller
  ) async throws {
    _ = try await fixture.scripting.requestLayout(
      anchor: .pane(ScriptPaneReference(window: who.window, pane: anchor.rawValue)),
      layout: layout, caller: who, stillAllowed: {})
  }

  /// Catches an owner's next layout that closes or dismisses a form asked from one of its members.
  /// The Questions pane is split beside a member of the owner's group, so the group holds a pane
  /// the owner does not own. The owner's next layout is refused whole, as for any pane the user
  /// split off, and the Questions pane, its tab, and its form stay as they were.
  func testAnOwnersNextLayoutNeverDismissesAFormAskedFromItsMember() async throws {
    let fixture = makeFixture()
    let (controller, pane) = try fixture.openWindow()
    let source = NodeID(rawValue: pane.pane)
    let owner = fixture.caller

    try await layOut(fixture, presentation(source), from: source, as: owner)

    let member = try XCTUnwrap(controller.paneArea.tree.paneIDs.first { $0 != source })
    let asker = ScriptCaller(connection: 2, window: owner.window, pane: member)
    let heard = try ask(fixture, as: "a", from: asker)
    let found = try questions(in: controller)

    do {
      try await layOut(
        fixture,
        #"{"split":"column","children":["#
          + #"{"pane":\#(source.rawValue)},{"pane":\#(member.rawValue)}]}"#,
        from: source, as: owner)
      XCTFail("the owner's layout changed a group that holds the Questions pane")
    } catch let error as ScriptCallError {
      XCTAssertEqual(error.kind, .refused)
      XCTAssertTrue(error.text.contains("does not own"), error.text)
    }

    let after = try questions(in: controller)

    XCTAssertEqual(after.pane, found.pane)
    XCTAssertTrue(after.applet.hasOpenForm(forRequester: "a"))
    XCTAssertTrue(heard.outcomes.isEmpty, "the layout dismissed the form")
    XCTAssertTrue(controller.paneArea.tree.paneIDs.contains(found.pane))
  }

  /// Traces whether the refusal outlasts the answer. A resolved tab keeps the Questions pane open,
  /// so the owner's layout stays refused with the answer given, and the refusal names the pane. It
  /// ends when the last tab goes and the pane closes with it.
  func testTheRefusalOutlastsTheAnswerAndEndsWithTheQuestionsPane() async throws {
    let fixture = makeFixture()
    let (controller, pane) = try fixture.openWindow()
    let source = NodeID(rawValue: pane.pane)
    let owner = fixture.caller

    try await layOut(fixture, presentation(source), from: source, as: owner)

    let member = try XCTUnwrap(controller.paneArea.tree.paneIDs.first { $0 != source })
    let asker = ScriptCaller(connection: 2, window: owner.window, pane: member)

    _ = try ask(fixture, as: "a", from: asker)
    controller.discardForm(requester: "a")

    let again =
      #"{"split":"column","children":[{"pane":\#(source.rawValue)},{"pane":\#(member.rawValue)}]}"#

    do {
      try await layOut(fixture, again, from: source, as: owner)
      XCTFail("the layout went ahead beside a resolved Questions pane")
    } catch let error as ScriptCallError {
      XCTAssertTrue(error.text.contains("Questions pane"), error.text)
      XCTAssertTrue(error.text.contains("Close the Questions pane"), error.text)
    }

    controller.endForm(requester: "a")

    XCTAssertNil(controller.questionsPane())

    try await layOut(fixture, again, from: source, as: owner)
  }

  /// Catches a first layout that takes a Questions pane beside its source into the group or drops
  /// it. The form is asked from the source pane, the owner lays out from it, and the Questions pane
  /// keeps its place and its form.
  func testAFirstLayoutFromTheAskerLeavesTheQuestionsPaneAlone() async throws {
    let fixture = makeFixture()
    let (controller, pane) = try fixture.openWindow()
    let source = NodeID(rawValue: pane.pane)
    let asker = ScriptCaller(connection: 2, window: fixture.caller.window, pane: source)
    let heard = try ask(fixture, as: "a", from: asker)
    let found = try questions(in: controller)

    try await layOut(fixture, presentation(source), from: source, as: fixture.caller)

    let after = try questions(in: controller)

    XCTAssertEqual(after.pane, found.pane)
    XCTAssertTrue(after.applet.hasOpenForm(forRequester: "a"))
    XCTAssertTrue(heard.outcomes.isEmpty)
  }

  // MARK: Helpers

  private static func text(in view: NSView, contains fragment: String) -> Bool {
    if let field = view as? NSTextField, field.stringValue.contains(fragment) { return true }

    return view.subviews.contains { text(in: $0, contains: fragment) }
  }
}
