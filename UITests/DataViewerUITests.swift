import AppKit
import XCTest

/// Drives the data viewer in the launched app. Each test proves a contract that needs the real
/// window server: the launcher entry, the open panel, the router's choice of applet for a CSV
/// file, and a layout that comes back over a relaunch.
///
/// A drop of several files is refused with a message, but XCUITest cannot start a drag from
/// Finder. The package tests prove that rule on the applet's drop entry point.
@MainActor
final class DataViewerUITests: UnitermUITestCase {
  private let closeWindowsOnQuit = ["-NSQuitAlwaysKeepsWindows", "NO"]
  private let quitSavesOnly = ["UNITERM_LAYOUT_DEBOUNCE": "3600"]

  private func makeCSV(_ text: String, name: String = "sales.csv") throws -> URL {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("uniterm-data-\(UUID().uuidString)", isDirectory: true)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }

    let file = folder.appendingPathComponent(name)
    try Data(text.utf8).write(to: file)
    return file
  }

  private func plantViewer(path: String, extra: String = "") throws {
    try plantLayout(
      """
      {"version":1,"windows":[{"frame":{"x":100,"y":100,"width":900,"height":600},"highWaterMark":1,
      "tree":{"kind":"pane","id":1,"applet":{"type":"data-viewer","version":1,
      "payload":{"startDirectory":"\(URL(fileURLWithPath: path).deletingLastPathComponent().path)",
      "path":"\(path)"\(extra)}}}}]}
      """)
  }

  private func viewer(in window: XCUIElement) -> XCUIElement {
    window.descendants(matching: .any)["data-viewer"]
  }

  private func countText(in window: XCUIElement) -> XCUIElement {
    window.descendants(matching: .any).matching(identifier: "status-applet-0").firstMatch
  }

  /// Chooses a file in the open panel that is already showing, by typing its path into the
  /// go-to-folder sheet.
  private func choose(_ file: URL, in app: XCUIApplication, window: XCUIElement) {
    let panel = window.sheets.firstMatch
    XCTAssertTrue(panel.waitForExistence(timeout: 10), "no open panel")

    app.typeKey("g", modifierFlags: [.command, .shift])

    let goTo = panel.sheets.firstMatch
    XCTAssertTrue(goTo.waitForExistence(timeout: 5), "no go-to-folder sheet")

    app.typeText(file.path)

    // A path that the field mangled while typing sends the panel nowhere. Say so before Return.
    let typed = goTo.textFields.firstMatch
    XCTAssertTrue(
      waitFor(typed, timeout: 5) { $0 == file.path }, "the go-to field holds the wrong path")

    app.typeKey(.return, modifierFlags: [])
    XCTAssertTrue(waitUntilGone(goTo, timeout: 5), "the go-to-folder sheet never closed")

    app.typeKey(.return, modifierFlags: [])
    XCTAssertTrue(waitForNoSheet(in: window, timeout: 10), "the panel never closed")
  }

  /// Catches a launcher without the data viewer, a pane that does not offer to open a file, and an
  /// open panel that does not end in a table. Cmd-D shows the launcher, Cmd-3 picks the data
  /// viewer, and the pane's Open button opens a panel that loads the chosen file.
  func testLauncherOpensAnEmptyViewerAndItsOpenButtonLoadsAFile() throws {
    let file = try makeCSV("region,amount\neast,3\nwest,5\nnorth,2\n")
    let app = launchApp()
    let window = mainWindow(in: app)
    _ = waitForTerminal(in: app)

    app.typeKey("d", modifierFlags: .command)
    XCTAssertTrue(launcher(in: window).waitForExistence(timeout: 5))

    app.typeKey("3", modifierFlags: .command)
    app.typeKey(.return, modifierFlags: [])

    XCTAssertTrue(waitUntilGone(launcher(in: window)))
    XCTAssertTrue(viewer(in: window).waitForExistence(timeout: 10), "no data viewer pane")

    let open = window.buttons["data-viewer-open"]
    XCTAssertTrue(open.waitForExistence(timeout: 5), "an empty viewer has no Open button")
    open.click()

    choose(file, in: app, window: window)

    XCTAssertTrue(window.tables["data-viewer-table"].waitForExistence(timeout: 10), "no table")
    XCTAssertTrue(waitFor(countText(in: window), timeout: 10) { $0 == "3 rows" })
  }

  /// Catches Cmd-O routing a CSV file anywhere but the data viewer. The file opens in a new pane
  /// beside the terminal.
  func testCommandORoutesACSVFileToTheDataViewer() throws {
    let file = try makeCSV("region,amount\neast,3\n")
    let app = launchApp()
    let window = mainWindow(in: app)
    _ = waitForTerminal(in: app)

    app.typeKey("o", modifierFlags: .command)
    choose(file, in: app, window: window)

    XCTAssertTrue(window.tables["data-viewer-table"].waitForExistence(timeout: 15), "no table")
    XCTAssertTrue(window.textViews["terminal"].exists, "the terminal went away")
  }

  /// Catches a restore that loses the file, its sort, or its filter, and one that stores rows. The
  /// saved pane loads again at launch with the filter and the descending sort applied. After a quit
  /// the layout holds the path and the filter and none of the file's cells.
  func testARestoredViewerShowsTheFileWithItsSortAndFilterAndStoresNoRows() throws {
    let file = try makeCSV("name,amount\nax,3\nbx,1\ncy,2\ndx,5\n")

    try plantViewer(
      path: file.path,
      extra:
        #","filter":"x","sort":{"column":{"segments":["amount"],"occurrence":0},"ascending":false}"#
    )

    let app = launchApp(environment: quitSavesOnly, arguments: closeWindowsOnQuit)
    let window = mainWindow(in: app)

    XCTAssertTrue(window.tables["data-viewer-table"].waitForExistence(timeout: 20), "no table")
    XCTAssertTrue(waitFor(countText(in: window), timeout: 10) { $0 == "3 of 4 rows" })

    let first = window.tables["data-viewer-table"].cells.element(boundBy: 0)
    XCTAssertTrue(first.staticTexts["dx"].waitForExistence(timeout: 5), "the sort did not apply")

    app.typeKey("q", modifierFlags: .command)
    XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))

    // The layout encoder writes "/" as "\/", which is valid JSON for the same string.
    let written = try String(
      contentsOf: layoutDirectory.appendingPathComponent("layout.json"), encoding: .utf8
    ).replacingOccurrences(of: "\\/", with: "/")

    XCTAssertTrue(written.contains(file.path), "the path was not saved: \(written)")
    XCTAssertTrue(written.contains(#""filter":"x""#))
    XCTAssertFalse(written.contains("dx"), "rows were saved in the layout")
  }

  /// Catches a missing file that shows an empty table or crashes the restore. The pane says the
  /// file is missing.
  func testARestoredViewerWhoseFileIsGoneSaysSo() throws {
    try plantViewer(path: "/private/tmp/uniterm-no-such-file-\(UUID().uuidString).csv")

    let app = launchApp()
    let window = mainWindow(in: app)
    let message = window.descendants(matching: .any).matching(identifier: "data-viewer-message")
      .firstMatch

    XCTAssertTrue(message.waitForExistence(timeout: 20), "no message")
    XCTAssertTrue(
      waitFor(message, timeout: 5) { $0.contains("missing") }, "the message does not say missing")
  }
}
