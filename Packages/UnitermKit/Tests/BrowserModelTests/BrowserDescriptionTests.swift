import XCTest

@testable import BrowserModel

/// The description payload: its stored shape, the version rule, and the bounds on what a page can
/// put into the layout file.
final class BrowserDescriptionTests: XCTestCase {
  private func encode(_ description: BrowserDescription) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]

    return String(decoding: try encoder.encode(description), as: UTF8.self)
  }

  /// Catches a payload that drifts from the stored shape: a tab array and a selected index, each
  /// tab holding a URL and a title. A later build reads exactly this, so the bytes are written out
  /// here by hand.
  func testTheStoredShapeIsATabArrayAndASelectedIndex() throws {
    let description = BrowserDescription(
      tabs: [.init(url: "https://example.com/a", title: "A")], selected: 0)

    XCTAssertEqual(
      try encode(description),
      #"{"selected":0,"tabs":[{"title":"A","url":"https:\/\/example.com\/a"}]}"#)
  }

  /// Catches a fresh pane whose payload holds no tab, which would need a version bump when tabs
  /// arrive.
  func testABlankPaneStoresOneEmptyTab() throws {
    XCTAssertEqual(try encode(BrowserDescription()), #"{"selected":0,"tabs":[{}]}"#)
  }

  /// Catches a reader that needs fields a writer may leave out, so a tab with no URL or title
  /// would be refused as damaged.
  func testATabWithNoFieldsReads() throws {
    let data = Data(#"{"selected":0,"tabs":[{}]}"#.utf8)
    let decoded = try JSONDecoder().decode(BrowserDescription.self, from: data)

    XCTAssertEqual(decoded, BrowserDescription())
    XCTAssertNoThrow(try decoded.validated(version: 1))
  }

  /// Catches a newer version read as if this build understood it, which would drop its fields on
  /// the next write. The caller keeps the original bytes on this error.
  func testANewerVersionIsRefused() {
    XCTAssertThrowsError(try BrowserDescription().validated(version: 2)) { error in
      XCTAssertEqual(
        error as? BrowserDescription.Failure, .newerVersion(found: 2, supported: 1))
    }
  }

  func testAVersionBelowOneIsDamage() {
    XCTAssertThrowsError(try BrowserDescription().validated(version: 0)) { error in
      guard case .corrupt = error as? BrowserDescription.Failure else {
        return XCTFail("expected corrupt, got \(error)")
      }
    }
  }

  /// Catches a payload with no tab, or a selection past the end, which would crash a restore that
  /// indexes the array.
  func testAnEmptyTabListAndAnOutOfRangeSelectionAreDamage() {
    for bad in [
      BrowserDescription(tabs: [], selected: 0),
      BrowserDescription(tabs: [.init()], selected: 1),
      BrowserDescription(tabs: [.init()], selected: -1),
    ] {
      XCTAssertThrowsError(try bad.validated(version: 1)) { error in
        guard case .corrupt = error as? BrowserDescription.Failure else {
          return XCTFail("expected corrupt, got \(error)")
        }
      }
    }
  }

  /// Catches a page title or URL that a page can grow without bound in the layout file, and an
  /// address no restore would load being stored.
  func testWhatAPageChoosesIsBoundedBeforeItIsStored() throws {
    let long = String(repeating: "t", count: BrowserDescription.maximumTitleCharacters + 50)

    XCTAssertEqual(
      BrowserDescription.boundedTitle(long)?.count, BrowserDescription.maximumTitleCharacters)
    XCTAssertNil(BrowserDescription.boundedTitle(""))
    XCTAssertNil(BrowserDescription.boundedTitle(nil))
    XCTAssertEqual(BrowserDescription.boundedTitle("Page"), "Page")

    XCTAssertEqual(
      BrowserDescription.storableURL(URL(string: "https://example.com/a")),
      "https://example.com/a")
    XCTAssertNil(BrowserDescription.storableURL(URL(string: "blob:https://example.com/1")))
    XCTAssertNil(BrowserDescription.storableURL(nil))

    let huge = "https://example.com/" + String(repeating: "a", count: 32 * 1024)

    XCTAssertNil(BrowserDescription.storableURL(URL(string: huge)))
  }
}
