import AppKit
import AppletKit
import PaneModel
import XCTest

@testable import WindowKit

/// A click on a path in a pane, from the applet's host to the router, with fixture applets. The
/// terminal applet's own rules are tested with it. These prove the chain below it: the pane's host,
/// its window, the set's router, and the placement beside the clicked pane.
@MainActor
final class TerminalClickRouteTests: XCTestCase {
  private func makeFixture() throws -> RoutingFixture {
    let fixture = try RoutingFixture()
    addTeardownBlock { @MainActor in fixture.cleanUp() }
    return fixture
  }

  /// Catches a click that never reaches the router, or one that lands in another window, replaces
  /// the clicked pane, or starts in the clicked pane's folder. The routed pane is the user's own
  /// act, so it takes the focus as File > Open does.
  func testAClickInAPaneOpensBesideThatPaneAndTakesTheFocus() async throws {
    let fixture = try makeFixture()
    fixture.windows.routedOpener = fixture.opener

    let anchor = try fixture.anchoredWindow()
    let clicked = try XCTUnwrap(anchor.controller.paneArea.applet(for: anchor.pane))
    let file = try fixture.textFile("a.txt")

    let host = try XCTUnwrap(clicked.host)
    host.applet(clicked, open: file)

    _ = await waitUntil { anchor.controller.paneIDs.count == 2 }

    XCTAssertEqual(anchor.controller.paneIDs.count, 2)
    XCTAssertEqual(fixture.windows.controllers.count, 1)
    XCTAssertTrue(anchor.controller.paneArea.applet(for: anchor.pane) === clicked)
    XCTAssertEqual(fixture.box.entries.map(\.file), [file])
    XCTAssertEqual(fixture.box.entries.map(\.start), [fixture.directory.path])
    XCTAssertNotEqual(anchor.controller.focusedPane, anchor.pane)
  }

  /// Catches a click in a second window that opens beside a pane of the first. The set's router is
  /// shared, and the anchor is the clicked pane's own window.
  func testAClickInASecondWindowOpensInThatWindow() async throws {
    let fixture = try makeFixture()
    fixture.windows.routedOpener = fixture.opener

    _ = try fixture.anchoredWindow()
    let second = try fixture.anchoredWindow()
    let clicked = try XCTUnwrap(second.controller.paneArea.applet(for: second.pane))
    let file = try fixture.textFile("a.txt")

    try XCTUnwrap(clicked.host).applet(clicked, open: file)

    _ = await waitUntil { second.controller.paneIDs.count == 2 }

    XCTAssertEqual(second.controller.paneIDs.count, 2)
    XCTAssertEqual(fixture.windows.controllers.first?.paneIDs.count, 1)
  }

  /// Catches a click that does nothing when the set has no router. It must say so in the window's
  /// status history, and open no pane.
  func testAClickWithNoRouterSaysSoAndOpensNothing() async throws {
    let fixture = try makeFixture()
    let anchor = try fixture.anchoredWindow()
    let clicked = try XCTUnwrap(anchor.controller.paneArea.applet(for: anchor.pane))

    try XCTUnwrap(clicked.host).applet(clicked, open: try fixture.textFile("a.txt"))

    XCTAssertEqual(
      anchor.controller.statusCenter.history.map(\.text),
      ["uniterm cannot open files from this pane."])
    XCTAssertEqual(anchor.controller.paneIDs.count, 1)
  }

  /// Catches a window opened after the router was set that never got it. Every new controller
  /// takes the set's router as it registers.
  func testAWindowOpenedAfterTheRouterWasSetStillRoutes() async throws {
    let fixture = try makeFixture()
    fixture.windows.routedOpener = fixture.opener

    let late = try fixture.anchoredWindow()

    XCTAssertTrue(late.controller.routedOpener === fixture.opener)
  }
}
