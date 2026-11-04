import AppKit
import AppletKit
import FileRouting
import XCTest

@testable import WindowKit

/// What a picker fixture saw, and what it answers.
@MainActor
private final class PanelScript {
  var requests: [OpenPanelRequest] = []
  var windows: [NSWindow?] = []
  var answer: [URL] = []
  var onPick: (@MainActor () -> Void)?

  var picker: OpenPicker {
    { [self] request, window in
      requests.append(request)
      windows.append(window)
      onPick?()
      return answer
    }
  }
}

/// File > Open and Open With, driven through a fixture panel and a fixture chooser. The real panel
/// and chooser are AppKit's, so these tests prove what the commands ask of them and what they do
/// with the answer. The UI test shows the real panel.
@MainActor
final class FileOpenCommandsTests: XCTestCase {
  private func makeFixture(extraClaims: Bool = false) throws -> RoutingFixture {
    let fixture = try RoutingFixture(terminalAlsoOpensText: extraClaims)
    addTeardownBlock { @MainActor in fixture.cleanUp() }
    return fixture
  }

  private func makeCommands(
    _ fixture: RoutingFixture, script: PanelScript,
    present: @escaping OpenWithPresenter = { _, _ in .cancelled },
    confirm: @escaping CloseConfirmer = { _, _ in true }
  ) -> FileOpenCommands {
    FileOpenCommands(
      opener: fixture.opener, picker: script.picker, present: present, confirm: confirm)
  }

  // MARK: Panel

  /// Catches a panel that starts in AppKit's remembered folder, or in the first pane's folder
  /// instead of the focused pane's. The focus is on the second pane, and it reports another folder.
  func testThePanelStartsInTheFocusedPanesDirectoryAndHangsFromItsWindow() async throws {
    let fixture = try makeFixture()
    let anchor = try fixture.anchoredWindow(directory: "/")
    let second = try XCTUnwrap(anchor.controller.openPane(.terminalShell, axis: .row))
    let secondApplet = try XCTUnwrap(fixture.log.made.last)
    secondApplet.currentDirectory = fixture.directory.path

    let script = PanelScript()
    let focused = RouteAnchor(controller: anchor.controller, pane: second)

    await makeCommands(fixture, script: script).open(from: focused)

    XCTAssertEqual(
      script.requests,
      [OpenPanelRequest(directory: fixture.directory, allowsMultipleSelection: true)])
    XCTAssertTrue(script.windows.first.flatMap { $0 } === anchor.controller.window)
  }

  /// Catches a panel with no starting folder when nothing reports one. Each case has its own way
  /// to report none: no window, an applet with no directory, and a directory that is gone.
  func testThePanelStartsInTheHomeFolderWhenNothingReportsADirectory() async throws {
    let fixture = try makeFixture()
    let home = FileManager.default.homeDirectoryForCurrentUser
    let script = PanelScript()
    let commands = makeCommands(fixture, script: script)

    await commands.open(from: nil)

    let silent = try fixture.anchoredWindow()
    try XCTUnwrap(fixture.log.made.last).currentDirectory = nil
    await commands.open(from: silent)

    try XCTUnwrap(fixture.log.made.last).currentDirectory = fixture.directory.path + "/gone"
    await commands.open(from: silent)

    XCTAssertEqual(script.requests.map(\.directory), [home, home, home])
    XCTAssertNil(script.windows[0])
  }

  /// Catches a panel that only takes one file, or one that cannot be told to take a single one.
  func testOpenAsksForSeveralFilesAndOpenWithForOne() async throws {
    let fixture = try makeFixture()
    let script = PanelScript()
    let commands = makeCommands(fixture, script: script)

    await commands.open(from: nil)
    await commands.openWith(from: nil)

    XCTAssertEqual(script.requests.map(\.allowsMultipleSelection), [true, false])
  }

  // MARK: Routing

  /// Catches a chosen file that opens in another window, or before the panel is gone. A single file
  /// anchors to the focused pane of the window whose menu ran the command, and starts in its own
  /// folder.
  func testAChosenFileOpensBesideTheFocusedPaneAfterThePanelIsGone() async throws {
    let fixture = try makeFixture()
    let anchor = try fixture.anchoredWindow()
    let file = try fixture.textFile("a.txt")

    let script = PanelScript()
    script.answer = [file]
    script.onPick = { XCTAssertTrue(fixture.box.entries.isEmpty, "routed before the panel closed") }

    await makeCommands(fixture, script: script).open(from: anchor)

    XCTAssertEqual(fixture.windows.controllers.count, 1)
    XCTAssertEqual(anchor.controller.paneIDs.count, 2)
    XCTAssertEqual(fixture.box.entries.map(\.file), [file])
    XCTAssertEqual(fixture.box.entries.map(\.start), [fixture.directory.path])
  }

  /// Catches a pane routed while the panel's sheet is still attached, which the router would answer
  /// with a new window. The picker returns with a real sheet on the window and ends it 100 ms later,
  /// longer than the router's own hop off the main thread. The pane must still land beside the anchor.
  func testAPaneIsNotPlacedUntilTheSheetHasLeftTheWindow() async throws {
    let fixture = try makeFixture()
    let anchor = try fixture.anchoredWindow()
    let window = try XCTUnwrap(anchor.controller.window)
    let file = try fixture.textFile("a.txt")

    let sheet = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 100, height: 50), styleMask: [.titled],
      backing: .buffered, defer: true)

    let script = PanelScript()
    script.answer = [file]
    script.onPick = {
      window.beginSheet(sheet)
      XCTAssertNotNil(window.attachedSheet)

      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { window.endSheet(sheet) }
    }

    await makeCommands(fixture, script: script).open(from: anchor)

    XCTAssertNil(window.attachedSheet)
    XCTAssertEqual(fixture.windows.controllers.count, 1)
    XCTAssertEqual(anchor.controller.paneIDs.count, 2)
  }

  /// Catches a chosen folder that does not open a terminal there, and a command with no window that
  /// opens nothing.
  func testAFolderChosenWithNoWindowOpensATerminalInANewWindow() async throws {
    let fixture = try makeFixture()
    let script = PanelScript()
    script.answer = [fixture.directory]

    await makeCommands(fixture, script: script).open(from: nil)

    XCTAssertEqual(fixture.windows.controllers.count, 1)
    XCTAssertEqual(fixture.box.entries.map(\.start), [fixture.directory.path])
  }

  /// Catches several chosen files split into the anchor's window one by one. A batch opens in one
  /// new window, each file splitting the largest pane.
  func testSeveralChosenFilesFollowTheBatchRule() async throws {
    let fixture = try makeFixture()
    let anchor = try fixture.anchoredWindow()
    let first = try fixture.textFile("a.txt")
    let second = try fixture.textFile("b.txt")

    let script = PanelScript()
    script.answer = [first, second]

    await makeCommands(fixture, script: script).open(from: anchor)

    XCTAssertEqual(fixture.windows.controllers.count, 2)
    XCTAssertEqual(anchor.controller.paneIDs.count, 1)
    XCTAssertEqual(fixture.windows.controllers.last?.paneIDs.count, 2)
    XCTAssertEqual(fixture.box.entries.map(\.file), [first, second])
  }

  /// Catches a cancelled panel that still opens something.
  func testCancellingThePanelOpensNothing() async throws {
    let fixture = try makeFixture()
    let anchor = try fixture.anchoredWindow()

    await makeCommands(fixture, script: PanelScript()).open(from: anchor)

    XCTAssertEqual(anchor.controller.paneIDs.count, 1)
    XCTAssertTrue(fixture.box.entries.isEmpty)
  }

  /// Catches a flood of panes from one selection. A batch above the threshold asks first, and a
  /// refusal opens nothing. The same batch opens when the user agrees.
  func testALargeSelectionAsksBeforeOpening() async throws {
    let fixture = try makeFixture()
    let files = try (0...LaunchOpenCoordinator.confirmationThreshold).map {
      try fixture.textFile("f\($0).txt")
    }

    let script = PanelScript()
    script.answer = files

    var questions: [String] = []

    await makeCommands(
      fixture, script: script,
      confirm: { question, _ in
        questions.append(question.title)
        return false
      }
    ).open(from: nil)

    XCTAssertEqual(questions, ["Open 11 files?"])
    XCTAssertTrue(fixture.box.entries.isEmpty)

    await makeCommands(fixture, script: script).open(from: nil)

    XCTAssertEqual(fixture.box.entries.count, 11)
  }

  // MARK: Open With

  /// Catches an Open With that ignores the pick. A file the rank sends to the viewer opens in the
  /// terminal when the user picks the terminal, and the chooser lists both.
  func testOpenWithOpensTheFileInTheAppletTheUserPicks() async throws {
    let fixture = try makeFixture(extraClaims: true)
    let anchor = try fixture.anchoredWindow()
    let file = try fixture.textFile("a.txt")

    let script = PanelScript()
    script.answer = [file]

    var listed: [String] = []

    await makeCommands(
      fixture, script: script,
      present: { model, _ in
        listed = model.candidates.map(\.typeID)
        return .open(appletTypeID: "terminal")
      }
    ).openWith(from: anchor)

    XCTAssertEqual(listed.sorted(), ["terminal", "viewer"])
    XCTAssertEqual(anchor.controller.paneIDs.count, 2)
    XCTAssertEqual(fixture.box.entries.count, 1)
    XCTAssertEqual(try XCTUnwrap(fixture.box.made.last).title, "terminal")
  }

  /// Catches an Open With that drops the chooser's save and clear. The checkbox saves the pick for
  /// the type, and the next plain open follows it. Clearing sends the next open back to the rank.
  func testOpenWithSavesAndClearsTheChoice() async throws {
    let fixture = try makeFixture(extraClaims: true)
    let file = try fixture.textFile("a.txt")

    let script = PanelScript()
    script.answer = [file]

    let saving = makeCommands(
      fixture, script: script,
      present: { model, _ in
        model.selection = "terminal"
        model.alwaysUse = true
        return .open(appletTypeID: model.confirm())
      })

    await saving.openWith(from: nil)

    XCTAssertEqual(
      SavedChoiceStore(defaults: fixture.defaults).choices().values.sorted(), ["terminal"])

    await makeCommands(fixture, script: script).open(from: nil)
    XCTAssertEqual(try XCTUnwrap(fixture.box.made.last).title, "terminal")

    let clearing = makeCommands(
      fixture, script: script,
      present: { model, _ in
        model.clearSavedChoice()
        return .clearedSavedChoice
      })

    await clearing.openWith(from: nil)

    XCTAssertTrue(SavedChoiceStore(defaults: fixture.defaults).choices().isEmpty)
    XCTAssertEqual(try XCTUnwrap(fixture.box.made.last).title, "viewer")
  }

  /// Catches a cancelled chooser that opens the file anyway.
  func testCancellingTheChooserOpensNothing() async throws {
    let fixture = try makeFixture()
    let script = PanelScript()
    script.answer = [try fixture.textFile("a.txt")]

    await makeCommands(fixture, script: script).openWith(from: nil)

    XCTAssertTrue(fixture.box.entries.isEmpty)
    XCTAssertTrue(fixture.windows.controllers.isEmpty)
  }

  /// Catches a file no applet declares that fails silently. The message names the file.
  func testOpenWithOnAnUnsupportedFileSaysSo() async throws {
    let fixture = try makeFixture()
    let anchor = try fixture.anchoredWindow()
    let file = fixture.directory.appendingPathComponent("blob.uniterm-unknown")
    try Data("x".utf8).write(to: file)

    let script = PanelScript()
    script.answer = [file]

    var asked = false

    await makeCommands(
      fixture, script: script,
      present: { _, _ in
        asked = true
        return .cancelled
      }
    )
    .openWith(from: anchor)

    XCTAssertFalse(asked)
    XCTAssertTrue(
      try XCTUnwrap(anchor.controller.statusCenter.history.last?.text).contains(
        "blob.uniterm-unknown"))
  }
}
