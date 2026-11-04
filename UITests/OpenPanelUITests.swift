import XCTest

/// File > Open on Cmd-O, driven through the real open panel. The panel is the system's, so this
/// shows what the unit tests' fixture panel cannot: the key reaches the panel from a terminal pane,
/// the panel hangs from the window, and the window has room for the routed pane once it closes.
@MainActor
final class OpenPanelUITests: UnitermUITestCase {
  /// Catches a Cmd-O that the focused terminal swallows, a panel that never appears, and a folder
  /// that opens anywhere but a new terminal beside the focused one, starting in that folder.
  func testCommandOShowsAPanelAndAFolderOpensATerminalBesideTheFocusedPane() throws {
    let name = "uniterm-open-\(UUID().uuidString)"
    let folder = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }

    let app = launchApp()
    let window = mainWindow(in: app)
    _ = waitForTerminal(in: app)

    app.typeKey("o", modifierFlags: .command)

    let panel = window.sheets.firstMatch
    XCTAssertTrue(panel.waitForExistence(timeout: 10), "Cmd-O never showed an open panel")

    let shot = XCTAttachment(screenshot: panel.screenshot())
    shot.name = "open-panel"
    shot.lifetime = .deleteOnSuccess
    add(shot)

    app.typeKey("g", modifierFlags: [.command, .shift])

    let goTo = panel.sheets.firstMatch
    XCTAssertTrue(goTo.waitForExistence(timeout: 5), "the go-to-folder sheet never appeared")

    app.typeText(folder.resolvingSymlinksInPath().path)
    app.typeKey(.return, modifierFlags: [])
    XCTAssertTrue(waitUntilGone(goTo, timeout: 5), "the go-to-folder sheet never closed")

    app.typeKey(.return, modifierFlags: [])

    XCTAssertTrue(waitForNoSheet(in: window, timeout: 10), "the panel never closed")

    let created = window.groups["pane-2"].textViews["terminal"]
    XCTAssertTrue(created.waitForExistence(timeout: 15), "no pane opened beside the first")
    XCTAssertEqual(window.textViews.matching(identifier: "terminal").count, 2)
    XCTAssertFalse(app.windows["main-window-2"].exists, "the folder opened in a new window")

    XCTAssertTrue(waitFor(created, timeout: 40) { $0.contains("% ") }, "no prompt")
    app.typeText("echo \"D:${PWD:t}:\"\n")
    XCTAssertTrue(waitFor(created, timeout: 20) { $0.contains("D:\(name):") })
  }
}
