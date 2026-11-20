import AppKit
import XCTest

@testable import WindowKit

/// Where a pane puts its applet's view.
@MainActor
final class PaneFrameViewTests: XCTestCase {
  /// Catches an applet frame that is not finite. A pane starts at zero size, before the first
  /// layout. Insetting zero bounds by the gutter gives the null rect, whose origin is infinite.
  /// AppKit then clamps that frame into a constraint and logs a warning on every launch.
  func testAPaneSmallerThanItsGutterGivesTheAppletAFiniteEmptyFrame() {
    for bounds in [NSRect.zero, NSRect(x: 0, y: 0, width: 3, height: 1)] {
      let frame = PaneFrameView.appletFrame(in: bounds)

      XCTAssertFalse(frame.isNull, "\(bounds)")
      XCTAssertTrue(frame.origin.x.isFinite && frame.origin.y.isFinite, "\(bounds)")
      XCTAssertEqual(frame.size, .zero, "\(bounds)")
    }
  }

  /// Catches a gutter that is lost once the pane has room. A 100 by 50 pane holds its applet 2
  /// points in from every edge.
  func testAPaneWithRoomInsetsItsAppletByTheGutter() {
    XCTAssertEqual(
      PaneFrameView.appletFrame(in: NSRect(x: 0, y: 0, width: 100, height: 50)),
      NSRect(x: 2, y: 2, width: 96, height: 46))
  }

  /// Catches a badge that hides on a disconnected pane while a controller acts from it. The user
  /// disconnects the terminal a controller started from. The controller keeps acting through the
  /// groups it owns. Pane chrome is then the only place that offers Revoke Controller on that
  /// pane. A pane with no controller and no other control stays in the default state, unbadged.
  func testADisconnectedPaneShowsItsBadgeWhileAControllerActsFromIt() {
    var mark = PaneControlMark(
      access: .disconnected, driver: .none, owner: nil, inUnownedGroup: false,
      enableAvailable: true, revokeAvailable: false)

    XCTAssertFalse(mark.isShown, "a default pane showed a badge")

    mark.controllers = ["script (PID 1)"]
    mark.revokeAvailable = true

    XCTAssertTrue(mark.isShown, "a live controller acting from the pane left it unbadged")
  }
}
