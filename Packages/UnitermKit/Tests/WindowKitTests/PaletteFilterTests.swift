import AppletKit
import PaneModel
import XCTest

@testable import WindowKit

/// The palette's filter rows and chips, apart from any view: what a keyword offers, what a chip
/// keeps, and what the list says when a chip leaves nothing.
final class PaletteFilterTests: XCTestCase {
  private let types = [
    AppletTypeDeclaration(
      typeID: "terminal", displayName: "Terminal", symbolName: "terminal", opens: []),
    AppletTypeDeclaration(
      typeID: "data-viewer", displayName: "Data Viewer", symbolName: "tablecells", opens: []),
    AppletTypeDeclaration(
      typeID: "browser", displayName: "Browser", symbolName: "safari", opens: []),
  ].map(PaletteAppletType.init)

  private var browser: PaletteAppletType { types[2] }

  private func tab(_ title: String, type: String, number: Int) -> PaletteCandidate {
    PaletteCandidate(
      entry: PaletteEntry(
        id: .tab(pane: NodeID(rawValue: 1), tab: AppletTabID(epoch: 1, serial: UInt64(number))),
        kind: .tab, title: title, appletTypeID: type, detail: nil, isEnabled: true),
      recencyRank: nil, order: number)
  }

  private func command(_ title: String, number: Int) -> PaletteCandidate {
    PaletteCandidate(
      entry: PaletteEntry(
        id: .command(CommandID(title)), kind: .command, title: title, detail: nil,
        isEnabled: true),
      recencyRank: nil, order: number)
  }

  private var candidates: [PaletteCandidate] {
    [
      tab("zsh", type: "terminal", number: 0),
      tab("Kagi Search", type: "browser", number: 1),
      tab("gUM audio", type: "browser", number: 2),
      command("Close Tab or Pane", number: 3),
      command("Split Right", number: 4),
    ]
  }

  private func list(_ query: String, filter: PaletteFilter? = nil) -> [PaletteEntry] {
    PaletteListing.entries(candidates, query: query, filter: filter, appletTypes: types)
  }

  /// Catches a hint that shows on one letter, where it would sit above most queries, or one that
  /// takes the highlight from the best result.
  func testTwoLettersOfAKeywordAddAHintThatNeverTakesTheHighlight() {
    XCTAssertFalse(list("a").contains { $0.kind == .filterKeyword })

    let rows = list("ap")
    XCTAssertEqual(rows.first?.id, .filterKeyword(.applet))
    XCTAssertFalse(rows[0].isSelectable)
    XCTAssertEqual(rows.dropFirst().first?.title, "Close Tab or Pane")

    XCTAssertEqual(list("ki").first?.id, .filterKeyword(.kind))
  }

  /// Catches a keyword that searches the results as text, or a name that matches only from its
  /// start, so "viewer" would miss Data Viewer.
  func testAKeywordListsTheValuesWhoseNameHasAWordStartingWithTheRest() {
    XCTAssertEqual(list("applet:").map(\.title), ["Terminal", "Data Viewer", "Browser"])
    XCTAssertEqual(list("Applet:br").map(\.title), ["Browser"])
    XCTAssertEqual(list("applet:viewer").map(\.title), ["Data Viewer"])
    XCTAssertEqual(list("applet:data-v").map(\.title), ["Data Viewer"])
    XCTAssertEqual(list("kind:").map(\.title), ["Tabs", "Commands"])
    XCTAssertEqual(list("applet:br").first?.id, .filter(.applet(browser)))
  }

  /// Catches a keyword with no match that shows nothing, so the list would vanish without saying
  /// why.
  func testAKeywordWithNoMatchSaysSo() {
    let rows = list("applet:zz")

    XCTAssertEqual(rows.map(\.kind), [.notice])
    XCTAssertEqual(rows.first?.title, "No applet named \u{201C}zz\u{201D}")
    XCTAssertFalse(rows[0].isSelectable)
  }

  /// Catches an applet chip that lets its commands or another applet's tabs through, or a chip
  /// whose text no longer searches.
  func testAnAppletChipKeepsOnlyThatAppletsTabs() {
    XCTAssertEqual(list("", filter: .applet(browser)).map(\.title), ["Kagi Search", "gUM audio"])
    XCTAssertEqual(list("kagi", filter: .applet(browser)).map(\.title), ["Kagi Search"])
  }

  /// Catches a kind chip that keeps the other kind.
  func testAKindChipKeepsOnlyThatKind() {
    XCTAssertEqual(list("", filter: .commands).map(\.title), ["Close Tab or Pane", "Split Right"])
    XCTAssertEqual(list("", filter: .tabs).map(\.kind), [.tab, .tab, .tab])
  }

  /// Catches a chip that leaves an empty list with no word of why.
  func testAChipThatLeavesNothingSaysSo() {
    let empty = PaletteAppletType(
      AppletTypeDeclaration(
        typeID: "map-viewer", displayName: "Map Viewer", symbolName: "map", opens: []))

    XCTAssertEqual(
      list("", filter: .applet(empty)).map(\.title), ["No Map Viewer tabs in this window"])
    XCTAssertEqual(list("zzz", filter: .applet(browser)).map(\.title), ["No Browser tabs match"])
  }

  /// Catches a keyword typed with a chip in place that searches inside the chip instead of
  /// offering a replacement.
  func testAKeywordStillOffersValuesWithAChipInPlace() {
    XCTAssertEqual(list("kind:co", filter: .applet(browser)).map(\.title), ["Commands"])
  }
}
