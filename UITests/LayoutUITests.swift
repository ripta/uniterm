import AppKit
import XCTest

/// Quits and relaunches the real app over a saved layout. Each test proves a contract that needs
/// the real window server, the real Cmd-Q path, and real shells.
///
/// The saved layout lives in a folder of its own for each test, so no test reads or writes the
/// developer's layout. The relaunches pass `-NSQuitAlwaysKeepsWindows NO`, which is what the
/// system setting "Close windows when quitting an application" does to an app. The layout must
/// come back anyway.
@MainActor
final class LayoutUITests: UnitermUITestCase {
  private let closeWindowsOnQuit = ["-NSQuitAlwaysKeepsWindows", "NO"]

  /// A debounce so long that only the save on quit can write the layout.
  private let quitSavesOnly = ["UNITERM_LAYOUT_DEBOUNCE": "3600"]

  private let shellDescription =
    #"{"type":"terminal","version":1,"payload":{"mode":"shell","tabs":[{"workingDirectory":null}],"selectedTab":0}}"#

  /// Catches a relaunch that loses the pane tree, a pane's ID, its place, or its shell's
  /// directory. The first launch makes three panes, with the third in a column under the second,
  /// and moves the third pane's shell to /usr/bin. After Cmd-Q and a relaunch the panes are in
  /// the same places, and the shell that holds focus starts in /usr/bin.
  func testQuitAndRelaunchRestoreTheSplitLayoutAndTheShellDirectory() throws {
    let app = launchApp(arguments: closeWindowsOnQuit)
    let window = mainWindow(in: app)
    _ = waitForTerminal(in: app)

    openPane(in: app, keys: "d", modifiers: .command)
    XCTAssertTrue(waitForPaneCount(2, in: window))
    openPane(in: app, keys: "d", modifiers: [.command, .shift])
    XCTAssertTrue(waitForPaneCount(3, in: window))

    let focused = panesInReadingOrder(in: window).last!
    XCTAssertTrue(waitFor(focused.textViews["terminal"], timeout: 40) { $0.contains("% ") })

    app.typeText("cd /usr/bin\n")
    let directory = window.descendants(matching: .any).matching(identifier: "status-applet-0")
      .firstMatch
    XCTAssertTrue(
      waitFor(directory, timeout: 15) { $0 == "bin" },
      "the status bar never showed the new directory")

    let before = panesInReadingOrder(in: window).map { ($0.identifier, $0.frame) }
    let windowFrame = window.frame

    app.typeKey("q", modifierFlags: .command)
    XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))

    let relaunched = launchApp(arguments: closeWindowsOnQuit)
    let restored = mainWindow(in: relaunched)
    XCTAssertTrue(restored.appears(timeout: 20))
    XCTAssertTrue(waitForPaneCount(3, in: restored))

    let after = panesInReadingOrder(in: restored).map { ($0.identifier, $0.frame) }

    XCTAssertEqual(after.map(\.0), before.map(\.0), "the pane IDs changed")

    for (old, new) in zip(before, after) {
      XCTAssertEqual(new.1.minX, old.1.minX, accuracy: 3, old.0)
      XCTAssertEqual(new.1.minY, old.1.minY, accuracy: 3, old.0)
      XCTAssertEqual(new.1.width, old.1.width, accuracy: 3, old.0)
      XCTAssertEqual(new.1.height, old.1.height, accuracy: 3, old.0)
    }

    XCTAssertEqual(restored.frame.minX, windowFrame.minX, accuracy: 3)
    XCTAssertEqual(restored.frame.width, windowFrame.width, accuracy: 3)

    let terminal = panesInReadingOrder(in: restored).last!.textViews["terminal"]
    XCTAssertTrue(waitFor(terminal, timeout: 40) { $0.contains("% ") })

    relaunched.typeText("pwd\n")
    XCTAssertTrue(
      waitFor(terminal, timeout: 20) { $0.contains("/usr/bin") },
      "the shell did not start in /usr/bin")
  }

  /// Catches a quit that drops a change made an instant before it. The save delay is an hour, so
  /// the split reaches the file only if Cmd-Q writes it.
  func testAChangeMadeJustBeforeQuitStillRestores() throws {
    let app = launchApp(environment: quitSavesOnly)
    let window = mainWindow(in: app)
    _ = waitForTerminal(in: app)

    openPane(in: app, keys: "d", modifiers: .command)
    XCTAssertTrue(waitForPaneCount(2, in: window))

    app.typeKey("q", modifierFlags: .command)
    XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))

    let relaunched = launchApp()
    XCTAssertTrue(waitForPaneCount(2, in: mainWindow(in: relaunched)))
  }

  /// Catches AppKit restoring a window on top of uniterm's own restore. Two windows, with two
  /// panes in the first, are open at Cmd-Q. After the relaunch there are exactly two windows, with
  /// the same pane counts.
  func testRelaunchOpensEachWindowOnceWhateverTheQuitSettingSays() throws {
    let app = launchApp(arguments: closeWindowsOnQuit)
    _ = waitForTerminal(in: app)

    openPane(in: app, keys: "d", modifiers: .command)
    XCTAssertTrue(waitForPaneCount(2, in: mainWindow(in: app)))

    app.typeKey("n", modifierFlags: .command)
    _ = waitForTerminal(in: app, window: 2)

    app.typeKey("q", modifierFlags: .command)
    XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))

    let relaunched = launchApp(arguments: closeWindowsOnQuit)
    XCTAssertTrue(mainWindow(in: relaunched).appears(timeout: 20))
    XCTAssertTrue(mainWindow(2, in: relaunched).appears(timeout: 20))
    XCTAssertTrue(waitForPaneCount(2, in: mainWindow(in: relaunched)))
    XCTAssertTrue(waitForPaneCount(1, in: mainWindow(2, in: relaunched)))

    // A copy from AppKit restoration would arrive during the launch. No event marks its absence, so
    // the check waits the shortest time that still covers window creation.
    Thread.sleep(forTimeInterval: 1)

    XCTAssertEqual(
      relaunched.windows.matching(NSPredicate(format: "identifier BEGINSWITH 'main-window'")).count,
      2, "a window was opened twice")
  }

  /// Catches a layout file that is read as trusted. Garbage on disk leaves a default window, keeps
  /// the file aside, and does not delete it.
  func testAnUnreadableLayoutFileIsKeptAsideAndADefaultWindowOpens() throws {
    try plantLayout("this is not a layout")

    let app = launchApp()
    _ = waitForTerminal(in: app)

    XCTAssertEqual(paneGroups(in: mainWindow(in: app)).count, 1)

    let kept = try FileManager.default.contentsOfDirectory(atPath: layoutDirectory.path)
      .filter { $0.hasPrefix("layout.aside-") }

    XCTAssertEqual(kept.count, 1, "the unreadable file was not kept aside")
    XCTAssertEqual(
      try String(contentsOf: layoutDirectory.appendingPathComponent(kept[0]), encoding: .utf8),
      "this is not a layout")
  }

  /// Catches a description that this build cannot read being dropped or rewritten. The second pane
  /// holds a description from a newer build. It shows a placeholder, and after a quit the file
  /// still holds those exact bytes. A second window is opened first, so the file must be
  /// rewritten, and the save delay is an hour, so the write is the one Cmd-Q makes.
  func testAnUnknownDescriptionShowsAPlaceholderAndSurvivesAQuitUnchanged() throws {
    let future =
      #"{ "type":"future-viewer", "version":9,  "payload":{"big":12345678901234567890} }"#

    try plantLayout(
      """
      {"version":1,"windows":[{"frame":{"x":100,"y":100,"width":1000,"height":600},"highWaterMark":3,
      "focusedPane":1,"tree":{"kind":"split","id":3,"axis":"row","children":[
      {"weight":0.5,"node":{"kind":"pane","id":1,"applet":\(shellDescription)}},
      {"weight":0.5,"node":{"kind":"pane","id":2,"applet":\(future)}}]}}]}
      """)

    let app = launchApp(environment: quitSavesOnly)
    let window = mainWindow(in: app)
    _ = waitForTerminal(in: app)

    let placeholder = window.descendants(matching: .any).matching(identifier: "placeholder-pane")
      .firstMatch
    XCTAssertTrue(placeholder.appears(timeout: 10), "no placeholder pane")

    app.typeKey("n", modifierFlags: .command)
    _ = waitForTerminal(in: app, window: 2)

    app.typeKey("q", modifierFlags: .command)
    XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))

    let written = try String(
      contentsOf: layoutDirectory.appendingPathComponent("layout.json"), encoding: .utf8)

    XCTAssertEqual(
      written.components(separatedBy: #""frame""#).count, 3, "the new window was not saved")
    XCTAssertTrue(written.contains(#""applet":\#(future)}"#), "the description changed: \(written)")
  }

  /// Catches a restore that runs a program. A saved program-mode pane shows its command and a Run
  /// button, and starts nothing. The command would create a marker file if it ran.
  func testAProgramModePaneRestoresWithoutRunningItsCommand() throws {
    let marker = layoutDirectory.appendingPathComponent("ran")
    try FileManager.default.createDirectory(at: layoutDirectory, withIntermediateDirectories: true)

    let program =
      #"{"type":"terminal","version":1,"payload":{"mode":"program","command":"/usr/bin/touch \#(marker.path)","tabs":[{"workingDirectory":null}],"selectedTab":0}}"#

    try plantLayout(
      """
      {"version":1,"windows":[{"frame":{"x":100,"y":100,"width":900,"height":600},"highWaterMark":1,
      "tree":{"kind":"pane","id":1,"applet":\(program)}}]}
      """)

    let app = launchApp()
    let prompt = mainWindow(in: app).descendants(matching: .any)
      .matching(identifier: "terminal-run-prompt").firstMatch

    XCTAssertTrue(prompt.appears(timeout: 20), "the Run prompt never showed")
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "the command ran")
  }

  /// A window saved on a screen that is gone opens on the screens that exist now.
  func testAWindowSavedOffscreenOpensOnAVisibleScreen() throws {
    try plantLayout(
      """
      {"version":1,"windows":[{"frame":{"x":20000,"y":20000,"width":800,"height":500},
      "screen":{"x":19000,"y":19000,"width":2000,"height":1200},"highWaterMark":1,
      "tree":{"kind":"pane","id":1,"applet":\(shellDescription)}}]}
      """)

    let app = launchApp()
    let window = mainWindow(in: app)
    XCTAssertTrue(window.appears(timeout: 20))

    let screens = NSScreen.screens.map(\.frame)
    let right = screens.map(\.maxX).max() ?? 0
    let left = screens.map(\.minX).min() ?? 0

    XCTAssertGreaterThanOrEqual(window.frame.minX, left)
    XCTAssertLessThanOrEqual(window.frame.maxX, right)
  }

  // MARK: Helpers

  private func paneGroups(in window: XCUIElement) -> XCUIElementQuery {
    window.groups.matching(NSPredicate(format: "identifier BEGINSWITH 'pane-'"))
  }

  private func waitForPaneCount(_ count: Int, in window: XCUIElement, timeout: TimeInterval = 20)
    -> Bool
  {
    let deadline = Date().addingTimeInterval(timeout)

    while Date() < deadline {
      if paneGroups(in: window).count == count { return true }

      Thread.sleep(forTimeInterval: 0.25)
    }

    return false
  }

  private func panesInReadingOrder(in window: XCUIElement) -> [XCUIElement] {
    paneGroups(in: window).allElementsBoundByIndex.sorted {
      let a = $0.frame
      let b = $1.frame
      return (a.minX.rounded(), a.minY.rounded()) < (b.minX.rounded(), b.minY.rounded())
    }
  }
}
