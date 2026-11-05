import AppKit
import XCTest

/// Drives the map viewer in the launched app. Each test proves a contract that needs the real window
/// server: the launcher entry, the View menu's style commands, and a layout that keeps the style and
/// the region over a relaunch.
///
/// The map itself is MapKit's, and XCUITest sees little of it. The pane's status segment names the
/// style, and the map's accessibility value holds the style and the saved center.
@MainActor
final class MapViewerUITests: UnitermUITestCase {
  private let closeWindowsOnQuit = ["-NSQuitAlwaysKeepsWindows", "NO"]
  private let quitSavesOnly = ["UNITERM_LAYOUT_DEBOUNCE": "3600"]

  private func plantMap(payload: String) throws {
    try plantLayout(
      """
      {"version":1,"windows":[{"frame":{"x":100,"y":100,"width":900,"height":600},"highWaterMark":1,
      "tree":{"kind":"pane","id":1,"applet":{"type":"map-viewer","version":1,
      "payload":\(payload)}}}]}
      """)
  }

  private func map(in window: XCUIElement) -> XCUIElement {
    window.descendants(matching: .any)["map-viewer"]
  }

  private func styleText(in window: XCUIElement) -> XCUIElement {
    window.descendants(matching: .any).matching(identifier: "status-applet-0").firstMatch
  }

  private func chooseStyle(_ title: String, in app: XCUIApplication) {
    let view = app.menuBars.menuBarItems["View"]
    view.click()

    let item = view.menus.menuItems[title]
    XCTAssertTrue(item.waitForExistence(timeout: 5), "the View menu has no \(title)")
    item.click()
  }

  /// Catches a launcher without the map viewer, a pane that shows no map, and a style command that
  /// does not reach the pane. Cmd-D shows the launcher, Cmd-4 picks the map viewer, and each style
  /// in the View menu shows in the status bar and in the map's accessibility value.
  func testLauncherOpensAMapAndTheViewMenuSwitchesItsStyle() throws {
    let app = launchApp()
    let window = mainWindow(in: app)
    _ = waitForTerminal(in: app)

    app.typeKey("d", modifierFlags: .command)
    XCTAssertTrue(launcher(in: window).waitForExistence(timeout: 5))

    app.typeKey("4", modifierFlags: .command)
    app.typeKey(.return, modifierFlags: [])

    XCTAssertTrue(waitUntilGone(launcher(in: window)))
    XCTAssertTrue(map(in: window).waitForExistence(timeout: 10), "no map pane")
    XCTAssertTrue(waitFor(styleText(in: window), timeout: 10) { $0 == "Standard" })

    chooseStyle("Satellite Map", in: app)
    XCTAssertTrue(waitFor(styleText(in: window), timeout: 10) { $0 == "Satellite" })
    XCTAssertTrue(waitFor(map(in: window), timeout: 5) { $0.hasPrefix("satellite") })

    chooseStyle("Hybrid Map", in: app)
    XCTAssertTrue(waitFor(styleText(in: window), timeout: 10) { $0 == "Hybrid" })

    chooseStyle("Standard Map", in: app)
    XCTAssertTrue(waitFor(styleText(in: window), timeout: 10) { $0 == "Standard" })
  }

  /// Catches a restore that drops the stored style or region. A planted layout names the hybrid
  /// style and a region over San Francisco, and the pane shows both.
  func testAPlantedStyleAndRegionComeBack() throws {
    try plantMap(
      payload:
        #"{"style":"hybrid","region":{"center":{"latitude":37.5,"longitude":-122.25},"span":{"latitudeDelta":0.5,"longitudeDelta":0.75}}}"#
    )

    let app = launchApp()
    let window = mainWindow(in: app)

    XCTAssertTrue(map(in: window).waitForExistence(timeout: 20), "no map pane")
    XCTAssertTrue(waitFor(styleText(in: window), timeout: 10) { $0 == "Hybrid" })
    XCTAssertTrue(
      waitFor(map(in: window), timeout: 5) { $0 == "hybrid 37.50,-122.25" },
      "the map does not hold the stored region")
  }

  /// Catches a style that is chosen but not saved, and a stored style that this build does not
  /// know showing anything but the standard map. A satellite choice survives a quit and a relaunch,
  /// and a planted unknown style shows the standard map.
  func testTheStyleSurvivesARelaunchAndAnUnknownStyleShowsStandard() throws {
    try plantMap(payload: #"{"style":"standard"}"#)

    let first = launchApp(environment: quitSavesOnly, arguments: closeWindowsOnQuit)
    let firstWindow = mainWindow(in: first)

    XCTAssertTrue(map(in: firstWindow).waitForExistence(timeout: 20), "no map pane")

    chooseStyle("Satellite Map", in: first)
    XCTAssertTrue(waitFor(styleText(in: firstWindow), timeout: 10) { $0 == "Satellite" })

    first.typeKey("q", modifierFlags: .command)
    XCTAssertTrue(first.wait(for: .notRunning, timeout: 15))

    let written = try String(
      contentsOf: layoutDirectory.appendingPathComponent("layout.json"), encoding: .utf8)

    XCTAssertTrue(written.contains(#""style":"satellite""#), "the style was not saved: \(written)")

    let second = launchApp(environment: quitSavesOnly, arguments: closeWindowsOnQuit)
    let secondWindow = mainWindow(in: second)

    XCTAssertTrue(map(in: secondWindow).waitForExistence(timeout: 20), "no map pane")
    XCTAssertTrue(waitFor(styleText(in: secondWindow), timeout: 10) { $0 == "Satellite" })

    second.typeKey("q", modifierFlags: .command)
    XCTAssertTrue(second.wait(for: .notRunning, timeout: 15))

    try plantMap(payload: #"{"style":"terrain"}"#)

    let third = launchApp()
    let thirdWindow = mainWindow(in: third)

    XCTAssertTrue(map(in: thirdWindow).waitForExistence(timeout: 20), "no map pane")
    XCTAssertTrue(waitFor(styleText(in: thirdWindow), timeout: 10) { $0 == "Standard" })
  }
}
