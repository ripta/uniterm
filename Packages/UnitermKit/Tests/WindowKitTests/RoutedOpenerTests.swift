import AppKit
import AppletKit
import FileRouting
import PaneModel
import Preferences
import UniformTypeIdentifiers
import XCTest

@testable import WindowKit

/// Windows, a router, and fixture applets. A text file routes to a viewer. A folder routes to a
/// fixture terminal. Types come from the real type database, so the fixtures use real files.
@MainActor
final class RoutingFixture {
  let suite = "uniterm-routing-\(UUID().uuidString)"
  let defaults: UserDefaults
  let log = AppletLog()
  let windows: WindowSet
  let opener: RoutedOpener
  let directory: URL

  /// With `terminalAlsoOpensText`, the terminal claims plain text as an alternate, so the viewer
  /// owns text and the chooser lists both.
  init(terminalAlsoOpensText: Bool = false) throws {
    directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("uniterm-routed-\(UUID().uuidString)", isDirectory: true)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    defaults = UserDefaults(suiteName: suite)!

    let store = SettingsStore(defaults: defaults)
    let appearance = AppearanceController(store: store)
    let log = log

    let makeApplet: AppletFactory = { _, directory in
      log.requested.append(directory)

      let applet = FakeApplet()
      log.made.append(applet)
      return applet
    }

    let windows = WindowSet(
      visibleFrame: { _ in NSRect(x: 0, y: 0, width: 4000, height: 3000) },
      makeRoutedController: { identifier, applet in
        try MainWindowController(
          appearance: appearance, settings: store, identifier: identifier, startingWith: applet,
          makeApplet: makeApplet
        ).detachFromRealScreen()
      },
      makeController: { identifier, directory in
        try MainWindowController(
          appearance: appearance, settings: store, identifier: identifier, startingIn: directory,
          makeApplet: makeApplet
        ).detachFromRealScreen()
      })
    self.windows = windows

    let declarations = [
      AppletTypeDeclaration(
        typeID: "viewer", displayName: "Viewer", symbolName: "doc.text",
        opens: [OpenedType("public.plain-text", rank: .owner)]),
      AppletTypeDeclaration(
        typeID: "terminal", displayName: "Terminal", symbolName: "terminal",
        opens: [OpenedType("public.folder", rank: .owner)]
          + (terminalAlsoOpensText ? [OpenedType("public.plain-text", rank: .alternate)] : [])),
    ]

    var factories: [String: AppletSourceFactory] = [:]
    let box = RoutedBox()
    self.box = box

    for id in ["viewer", "terminal"] {
      factories[id] = { file, start in
        box.entries.append((file, start))

        let applet = FakeApplet()
        applet.title = id
        applet.currentDirectory = start
        box.made.append(applet)
        return applet
      }
    }

    opener = RoutedOpener(
      windows: windows, declarations: declarations, factories: factories,
      store: SavedChoiceStore(defaults: defaults),
      confirmBatch: { question, _ in
        box.asked.append(question.title)
        return box.approve
      })
  }

  let box: RoutedBox

  func cleanUp() {
    for controller in windows.controllers { controller.window?.close() }

    defaults.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: directory)
  }

  func textFile(_ name: String, in folder: URL? = nil) throws -> URL {
    let url = (folder ?? directory).appendingPathComponent(name)
    try Data("x".utf8).write(to: url)
    return url
  }

  /// A window with an ordinary first pane that reports another folder as its directory.
  func anchoredWindow(directory elsewhere: String = "/elsewhere") throws -> RouteAnchor {
    let controller = try windows.open()
    let first = try XCTUnwrap(log.made.last)
    first.currentDirectory = elsewhere
    return RouteAnchor(controller: controller, pane: controller.focusedPane)
  }
}

@MainActor
final class RoutedBox {
  var entries: [(file: URL, start: String)] = []
  var made: [FakeApplet] = []
  var asked: [String] = []
  var approve = true
}

@MainActor
final class RoutedOpenerTests: XCTestCase {
  private func makeFixture() throws -> RoutingFixture {
    let fixture = try RoutingFixture()
    addTeardownBlock { @MainActor in fixture.cleanUp() }
    return fixture
  }

  // MARK: Placement beside the anchor

  /// Catches a routed pane that lands in another window, replaces the anchor's source, or starts
  /// in the anchor's folder. The anchor reports another folder, and the file's folder wins.
  func testARoutedFileSplitsBesideTheAnchorAndStartsInItsOwnFolder() async throws {
    let fixture = try makeFixture()
    let anchor = try fixture.anchoredWindow()
    let original = try XCTUnwrap(anchor.controller.paneArea.applet(for: anchor.pane))
    let file = try fixture.textFile("a.txt")

    let report = await fixture.opener.open([file], from: anchor)

    XCTAssertEqual(fixture.windows.controllers.count, 1)
    XCTAssertEqual(anchor.controller.paneIDs.count, 2)
    XCTAssertTrue(anchor.controller.paneArea.applet(for: anchor.pane) === original)
    XCTAssertEqual(report.opened.count, 1)
    XCTAssertTrue(report.opened[0].controller === anchor.controller)
    XCTAssertEqual(fixture.box.entries.map(\.start), [fixture.directory.path])
    XCTAssertEqual(fixture.box.entries.map(\.file), [file])
    XCTAssertEqual(anchor.controller.focusedPane, report.opened[0].pane)
  }

  /// Catches a routed pane that joins a group a controller owns. The anchor is a member of a
  /// group, and the routed pane lands beside it but outside the membership, with no control.
  func testARoutedSplitNeverJoinsAControllerGroup() async throws {
    let fixture = try makeFixture()
    let anchor = try fixture.anchoredWindow()
    let owner = GroupOwner(connection: 41)

    let member = try XCTUnwrap(
      anchor.controller.openPane(
        .terminalShell, typeID: "fake", axis: .row, from: anchor.pane, directory: nil,
        owner: owner, access: .disconnected))

    XCTAssertEqual(anchor.controller.owner(of: member), owner)

    let report = await fixture.opener.open(
      [try fixture.textFile("a.txt")],
      from: RouteAnchor(controller: anchor.controller, pane: member))

    let created = try XCTUnwrap(report.opened.first?.pane)

    XCTAssertNil(anchor.controller.owner(of: created))
    XCTAssertFalse(
      anchor.controller.paneArea.tree.groups.contains { $0.members.contains(created) })
    XCTAssertEqual(anchor.controller.control(of: created).access, .disconnected)
  }

  /// Catches a window whose panes start in a group, or with an owner, before any controller asked.
  func testNoControllerOwnsAGroupYet() throws {
    let fixture = try makeFixture()
    let anchor = try fixture.anchoredWindow()

    XCTAssertNil(anchor.controller.owner(of: anchor.pane))
    XCTAssertTrue(anchor.controller.paneArea.tree.groups.isEmpty)
  }

  // MARK: New windows

  /// Catches a routed window that starts a shell beside the routed pane, or takes a directory from
  /// another window. The factory is never called for the window's first pane.
  func testANewWindowHoldsOnlyTheRoutedPaneAndInheritsNoDirectory() async throws {
    let fixture = try makeFixture()
    let other = try fixture.anchoredWindow(directory: "/active/window")
    let madeBefore = fixture.log.made.count
    let requestedBefore = fixture.log.requested.count

    let report = await fixture.opener.open([try fixture.textFile("a.txt")], from: nil)

    let controller = try XCTUnwrap(report.opened.first?.controller)
    XCTAssertFalse(controller === other.controller)
    XCTAssertEqual(fixture.windows.controllers.count, 2)
    XCTAssertEqual(controller.paneIDs.count, 1)
    XCTAssertEqual(fixture.log.made.count, madeBefore)
    XCTAssertEqual(fixture.log.requested.count, requestedBefore)
    XCTAssertEqual(fixture.box.entries.map(\.start), [fixture.directory.path])
  }

  /// Catches a folder routed to the terminal that opens a shell and then the folder. The routed
  /// pane is the window's only pane and starts in the folder.
  func testAFolderOpensANewTerminalPaneAtTheFolder() async throws {
    let fixture = try makeFixture()
    let folder = fixture.directory.appendingPathComponent("project", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

    let report = await fixture.opener.open([folder], from: nil)

    XCTAssertEqual(report.opened.first?.controller.paneIDs.count, 1)
    XCTAssertEqual(fixture.box.entries.map(\.start), [folder.path])
    XCTAssertEqual(fixture.log.made.count, 0)
  }

  /// Catches a split into a window with a sheet attached. The sheet holds the window's attention,
  /// so the file opens in a new window.
  func testAWindowWithASheetCountsAsHavingNoRoom() async throws {
    let fixture = try makeFixture()
    let anchor = try fixture.anchoredWindow()
    let window = try XCTUnwrap(anchor.controller.window)
    window.orderFrontRegardless()

    let sheet = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.beginSheet(sheet, completionHandler: nil)
    XCTAssertNotNil(window.attachedSheet)

    let report = await fixture.opener.open([try fixture.textFile("a.txt")], from: anchor)

    XCTAssertEqual(anchor.controller.paneIDs.count, 1)
    XCTAssertEqual(fixture.windows.controllers.count, 2)
    XCTAssertFalse(report.opened[0].controller === anchor.controller)
  }

  /// Catches a split forced into a window with no room. Panes fill the window, and the next file
  /// opens in a new window.
  func testAFileThatFindsNoRoomOpensInANewWindow() async throws {
    let fixture = try makeFixture()
    let anchor = try fixture.anchoredWindow()

    while anchor.controller.placeRoutedInLargestPane(FakeApplet()) != nil {}
    let full = anchor.controller.paneIDs.count

    let report = await fixture.opener.open([try fixture.textFile("a.txt")], from: anchor)

    XCTAssertEqual(anchor.controller.paneIDs.count, full)
    XCTAssertEqual(fixture.windows.controllers.count, 2)
    XCTAssertFalse(report.opened[0].controller === anchor.controller)
  }

  // MARK: Batches

  /// Catches a batch of exactly the threshold that asks, a batch above it that does not, and a
  /// declined question that opens anyway. The route owns the question, so every entry point asks.
  func testOnlyABatchAboveTheThresholdAsksAndADeclineOpensNothing() async throws {
    let fixture = try makeFixture()
    let limit = RoutedOpener.confirmationThreshold
    XCTAssertEqual(limit, 10)

    let atLimit = try (0..<limit).map { try fixture.textFile("at\($0).txt") }
    await fixture.opener.open(atLimit, from: nil)

    XCTAssertTrue(fixture.box.asked.isEmpty)
    XCTAssertEqual(fixture.box.entries.count, limit)

    let over = try (0...limit).map { try fixture.textFile("over\($0).txt") }
    fixture.box.approve = false
    let declined = await fixture.opener.open(over, from: nil)

    XCTAssertEqual(fixture.box.asked, ["Open \(limit + 1) files?"])
    XCTAssertTrue(declined.opened.isEmpty)
    XCTAssertEqual(fixture.box.entries.count, limit)

    fixture.box.approve = true
    await fixture.opener.open(over, from: nil)

    XCTAssertEqual(fixture.box.entries.count, limit + limit + 1)
  }

  /// Catches a batch that splits the anchor's window, or leaves a file out. A batch opens in one
  /// new window, and each file splits the largest pane there.
  func testABatchOpensInOneNewWindowSplittingTheLargestPane() async throws {
    let fixture = try makeFixture()
    let anchor = try fixture.anchoredWindow()
    let files = try (1...3).map { try fixture.textFile("f\($0).txt") }

    let report = await fixture.opener.open(files, from: anchor)

    XCTAssertEqual(anchor.controller.paneIDs.count, 1)
    XCTAssertEqual(fixture.windows.controllers.count, 2)

    let batch = try XCTUnwrap(report.opened.first?.controller)
    XCTAssertEqual(batch.paneIDs.count, 3)
    XCTAssertTrue(report.opened.allSatisfy { $0.controller === batch })
    XCTAssertEqual(report.opened.map(\.file), files)
  }

  /// Catches the choice of the largest pane. After one split of a window the two panes are equal,
  /// so the first in reading order is chosen. After that split the third pane is smaller, and the
  /// next split goes to a larger one.
  func testLargestPaneIsTheOneWithTheMostArea() throws {
    let fixture = try makeFixture()
    let anchor = try fixture.anchoredWindow()
    let controller = anchor.controller

    XCTAssertEqual(controller.largestPane(), anchor.pane)

    let second = try XCTUnwrap(controller.openPane(.terminalShell, axis: .row, from: anchor.pane))
    XCTAssertEqual(controller.largestPane(), anchor.pane)

    let third = try XCTUnwrap(controller.openPane(.terminalShell, axis: .row, from: anchor.pane))
    XCTAssertEqual(controller.largestPane(), second)
    XCTAssertNotEqual(third, second)
  }

  /// Catches a batch that stops halfway or drops files when a window fills. The files that find no
  /// room go to a further new window.
  func testABatchThatFillsItsWindowContinuesInAFurtherWindow() async throws {
    let fixture = try makeFixture()

    var capacity = 0
    let probe = try fixture.windows.open()
    while probe.placeRoutedInLargestPane(FakeApplet()) != nil { capacity += 1 }
    probe.window?.close()
    let windowsBefore = fixture.windows.controllers.count

    let files = try (0...(capacity + 1)).map { try fixture.textFile("f\($0).txt") }

    let report = await fixture.opener.open(files, from: nil)

    XCTAssertEqual(report.opened.count, files.count)
    XCTAssertEqual(Set(report.opened.map { ObjectIdentifier($0.controller) }).count, 2)
    XCTAssertEqual(fixture.windows.controllers.count, windowsBefore + 2)
  }

  // MARK: Refusals

  /// Catches a refusal that names neither the file nor its type.
  func testARefusedFileIsPostedByNameAndType() async throws {
    let fixture = try makeFixture()
    let anchor = try fixture.anchoredWindow()
    let file = fixture.directory.appendingPathComponent("a.bin")
    try Data("x".utf8).write(to: file)

    let report = await fixture.opener.open([file], from: anchor)

    XCTAssertTrue(report.opened.isEmpty)
    XCTAssertEqual(anchor.controller.paneIDs.count, 1)

    let text = try XCTUnwrap(anchor.controller.statusCenter.history.last?.text)
    XCTAssertTrue(text.contains("a.bin"))
    XCTAssertTrue(text.contains(try XCTUnwrap(UTType(filenameExtension: "bin")?.identifier)))
  }

  /// Catches a batch that posts one message for every failure. The good file still opens.
  func testManyFailuresMakeOneSummaryMessage() async throws {
    let fixture = try makeFixture()
    let anchor = try fixture.anchoredWindow()
    let good = try fixture.textFile("good.txt")

    var files = [good]
    for index in 0..<5 {
      files.append(fixture.directory.appendingPathComponent("missing\(index).txt"))
    }

    let before = anchor.controller.statusCenter.history.count
    let report = await fixture.opener.open(files, from: anchor)

    XCTAssertEqual(report.opened.count, 1)
    XCTAssertEqual(report.failures.count, 5)
    XCTAssertEqual(anchor.controller.statusCenter.history.count, before + 1)

    let text = try XCTUnwrap(anchor.controller.statusCenter.history.last?.text)
    XCTAssertTrue(text.contains("5 of 6 files were not opened"))
    XCTAssertTrue(text.contains("And 2 more."))
  }

  /// Catches an equal tie that the opener settles silently. With no chooser the file is refused.
  func testWithNoChooserATieIsRefusedAndNeverPicked() async throws {
    let fixture = try makeFixture()
    let tied = [
      AppletTypeDeclaration(
        typeID: "one", displayName: "One", symbolName: "doc",
        opens: [OpenedType("public.plain-text", rank: .owner)]),
      AppletTypeDeclaration(
        typeID: "two", displayName: "Two", symbolName: "doc",
        opens: [OpenedType("public.plain-text", rank: .owner)]),
    ]

    let opener = RoutedOpener(
      windows: fixture.windows, declarations: tied,
      factories: ["one": { _, _ in FakeApplet() }, "two": { _, _ in FakeApplet() }],
      store: SavedChoiceStore(defaults: fixture.defaults))

    let report = await opener.open([try fixture.textFile("a.txt")], from: nil)

    XCTAssertTrue(report.opened.isEmpty)
    XCTAssertEqual(fixture.windows.controllers.count, 0)
    XCTAssertTrue(report.failures[0].contains("more than one applet"))
  }

  /// Catches a window opened by the routed path that borrows the active window's directory.
  func testWindowSetOpensARoutedWindowWithoutADirectory() throws {
    let fixture = try makeFixture()
    _ = try fixture.anchoredWindow(directory: "/active/window")
    let requested = fixture.log.requested

    let applet = FakeApplet()
    let controller = try fixture.windows.open(routing: applet)

    XCTAssertEqual(fixture.log.requested.count, requested.count)
    XCTAssertTrue(controller.paneArea.applet(for: controller.focusedPane) === applet)
  }
}
