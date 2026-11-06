import AppKit
import AppletKit
import Preferences
import StatusKit
import XCTest

@testable import WindowKit

/// Every expected value is written out by hand from the rules in the type, never read back from it.
final class StatusBarContentTests: XCTestCase {
  private func display(
    _ level: StatusLevel, _ source: StatusSource, _ text: String, errorsBefore: Int = 0
  ) -> StatusDisplay? {
    var queue = StatusQueue()

    for index in 0..<errorsBefore {
      queue.post(level: .error, source: .uniterm, text: "old\(index)", at: 0)
    }

    queue.post(level: level, source: source, text: text, at: 0)
    queue.advance(at: 1.5)

    return queue.current
  }

  /// Catches a bar with no message area while idle.
  func testAnIdleBarKeepsAnEmptyMessageArea() {
    let segments = StatusBarContent.segments(display: nil, hasUnseenError: false, applet: [])

    XCTAssertEqual(
      segments, [BarSegment(id: .message, symbolName: nil, text: "", tone: .normal)])
  }

  /// Catches a window slot that sits among the applet's slots, or is displaced by an error and its
  /// indicators. The window's slots come first in a fixed order, and the applet's follow.
  func testTheWindowsOwnSlotsPrecedeTheApplets() {
    let segments = StatusBarContent.segments(
      display: display(.error, .uniterm, "boom"), hasUnseenError: true,
      applet: [AppletSegment(text: "tmp")])

    XCTAssertEqual(segments.map(\.id), [.message, .dismiss, .unseenError, .applet(0)])
  }

  /// Catches window slots in the wrong order, or displaced by an error. The three kinds show in
  /// their fixed order whatever order they were set in. They sit after the message, dismiss, and
  /// unseen indicator, and before the applet's segments. Each is compact, and its full sentence is
  /// both the tooltip and the accessibility label.
  func testWindowStatesShowInFixedOrderBeforeTheAppletSegments() {
    var states = WindowStates()
    states.set(.survivingWork, text: "Work is still running.")
    states.set(.layoutNotSaved, text: "Not saved.")
    states.set(.pendingPermissions, text: "A program is asking.")

    let segments = StatusBarContent.segments(
      display: display(.error, .uniterm, "boom"), hasUnseenError: true, windowStates: states,
      applet: [AppletSegment(text: "tmp")])

    XCTAssertEqual(
      segments.map(\.id),
      [
        .message, .dismiss, .unseenError, .window(.layoutNotSaved),
        .window(.pendingPermissions), .window(.survivingWork), .applet(0),
      ])

    for segment in segments {
      guard case .window = segment.id else { continue }

      XCTAssertNil(segment.text)
      XCTAssertNotNil(segment.symbolName)
      XCTAssertEqual(segment.toolTip, segment.accessibilityLabel)
    }

    XCTAssertEqual(segments[3].toolTip, "Not saved.")
    XCTAssertEqual(segments[5].toolTip, "Work is still running.")
  }

  /// Catches a kind whose symbol name is not a system symbol. The slot would show nothing, and
  /// the user would see no sign of the state.
  func testEveryWindowStateKindHasASymbolThatExists() throws {
    for kind in WindowStateKind.allCases {
      var states = WindowStates()
      states.set(kind, text: "x")

      let segment = try XCTUnwrap(
        StatusBarContent.segments(
          display: nil, hasUnseenError: false, windowStates: states, applet: []
        )
        .first { $0.id == .window(kind) })
      let name = try XCTUnwrap(segment.symbolName)

      XCTAssertNotNil(NSImage(systemSymbolName: name, accessibilityDescription: nil), name)
    }
  }

  /// Catches a message shown without its source, or with the wrong icon or tone for its level.
  func testTheMessageAreaShowsSourceTextAndLevelStyle() {
    let info = StatusBarContent.message(display(.info, .pane(id: 7, name: "zsh"), "done"))
    XCTAssertEqual(info.text, "zsh: done")
    XCTAssertEqual(info.symbolName, "info.circle")
    XCTAssertEqual(info.tone, .normal)

    let warning = StatusBarContent.message(display(.warning, .applet(id: 1, name: "git"), "dirty"))
    XCTAssertEqual(warning.text, "git (applet 1): dirty")
    XCTAssertEqual(warning.symbolName, "exclamationmark.triangle")
    XCTAssertEqual(warning.tone, .warning)

    let error = StatusBarContent.message(display(.error, .script(id: 2, name: "init"), "failed"))
    XCTAssertEqual(error.text, "init (script 2): failed")
    XCTAssertEqual(error.symbolName, "xmark.octagon")
    XCTAssertEqual(error.tone, .error)
  }

  /// Catches a producer that passes for the host by taking its name, and two same-named producers
  /// that read alike. Only the host reads as plain `uniterm`.
  func testOnlyTheHostReadsAsUniterm() {
    let host = StatusBarContent.message(display(.info, .uniterm, "ok"))
    let applet = StatusBarContent.message(display(.info, .applet(id: 4, name: "uniterm"), "ok"))
    let script = StatusBarContent.message(display(.info, .script(id: 5, name: "uniterm"), "ok"))
    let twin = StatusBarContent.message(display(.info, .script(id: 6, name: "uniterm"), "ok"))

    XCTAssertEqual(host.text, "uniterm: ok")
    XCTAssertEqual(applet.text, "uniterm (applet 4): ok")
    XCTAssertEqual(script.text, "uniterm (script 5): ok")
    XCTAssertNotEqual(script.text, twin.text)
  }

  /// Catches a folded error backlog that loses its count.
  ///
  /// The first of four errors is on the bar. The next two queue behind it and fold into the
  /// fourth, so the fourth shows with a count of 2.
  func testFoldedErrorsShowTheirCount() {
    let folded = display(.error, .uniterm, "boom", errorsBefore: 3)

    XCTAssertEqual(
      StatusBarContent.message(folded).text, "uniterm: boom  (+2 more errors)")
  }

  /// Catches segments in the wrong order, or an indicator without an error.
  func testSegmentsAreTheWindowsThenTheApplets() {
    let applet = [
      AppletSegment(symbolName: "folder", text: "tmp"),
      AppletSegment(symbolName: "xmark.circle", text: "2", style: .error),
      AppletSegment(text: "INSERT", style: .emphasized),
    ]

    let with = StatusBarContent.segments(display: nil, hasUnseenError: true, applet: applet)
    XCTAssertEqual(
      with.map(\.id), [.message, .unseenError, .applet(0), .applet(1), .applet(2)])
    XCTAssertEqual(with[1].symbolName, "exclamationmark.circle.fill")
    XCTAssertNil(with[1].text)
    XCTAssertEqual(with[1].tone, .error)
    XCTAssertEqual(with[1].accessibilityLabel, "Unseen errors")
    XCTAssertEqual(with.dropFirst(2).map(\.tone), [.normal, .error, .emphasized])
    XCTAssertEqual(with.dropFirst(2).map(\.text), ["tmp", "2", "INSERT"])

    let without = StatusBarContent.segments(display: nil, hasUnseenError: false, applet: applet)
    XCTAssertEqual(without.map(\.id), [.message, .applet(0), .applet(1), .applet(2)])
  }

  /// Catches a dismiss control on a message that clears itself, or none on an error.
  func testOnlyAnErrorOffersADismissControl() {
    let error = StatusBarContent.segments(
      display: display(.error, .uniterm, "boom"), hasUnseenError: true, applet: [])
    XCTAssertEqual(error.map(\.id), [.message, .dismiss, .unseenError])
    XCTAssertEqual(error[1].accessibilityLabel, "Dismiss message")

    for level in [StatusLevel.info, .warning] {
      let other = StatusBarContent.segments(
        display: display(level, .uniterm, "x"), hasUnseenError: false, applet: [])
      XCTAssertEqual(other.map(\.id), [.message])
    }
  }

  /// Catches history lines that drop the level, or put the source after the text. A pane's title
  /// is followed by its stable ID, since two panes can share a title.
  func testHistoryLinesCarryLevelSourceAndText() {
    var queue = StatusQueue()
    let message = queue.post(
      level: .warning, source: .pane(id: 3, name: "vim"), text: "swap file", at: 0)

    XCTAssertEqual(StatusBarContent.historyLine(message), "warning  vim (pane 3): swap file")
  }

  // MARK: Regions

  /// Catches a region that lands on the wrong edge's list.
  func testRegionsStackAgainstTheirOwnEdge() {
    let bottom = RegionStack.order([RegionPlacement(role: .statusBar, edge: .bottom)])
    XCTAssertEqual(bottom.top, [])
    XCTAssertEqual(bottom.bottom, [.statusBar])

    let top = RegionStack.order([RegionPlacement(role: .statusBar, edge: .top)])
    XCTAssertEqual(top.top, [.statusBar])
    XCTAssertEqual(top.bottom, [])
  }

  /// Catches a dock edge that does not follow the setting.
  func testTheDockEdgeFollowsTheSetting() {
    XCTAssertEqual(DockEdge(StatusBarPosition.top), .top)
    XCTAssertEqual(DockEdge(StatusBarPosition.bottom), .bottom)
    XCTAssertEqual(DockEdge(PaletteDockEdge.top), .top)
    XCTAssertEqual(DockEdge(PaletteDockEdge.bottom), .bottom)
  }
}
