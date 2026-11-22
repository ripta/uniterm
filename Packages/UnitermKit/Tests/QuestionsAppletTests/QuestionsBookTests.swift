import AppletKit
import XCTest

@testable import QuestionsApplet

/// Proves the tab rules that need no window: which form may open, which tab it takes, and which
/// tab gives way. The applet's own tests prove the same rules through its API. These pin the
/// order of eviction and the selection after a close, which the views never show directly.
@MainActor
final class QuestionsBookTests: XCTestCase {
  private func open(_ book: inout QuestionsBook, _ key: String) -> AppletTabID {
    let id = AppletTabID.make()

    book.open(requesterKey: key, id: id)

    return id
  }

  /// Catches a requester that opens a second form while one is open, which "One form at a time"
  /// refuses, and a requester's next form that opens a second tab instead of reusing its own.
  func testARequesterHasOneTabAndAnOpenFormRefusesTheNext() {
    var book = QuestionsBook()
    let first = open(&book, "a")

    XCTAssertEqual(book.admission(forRequester: "a"), .refused(.requesterBusy))

    book.resolve(first)

    XCTAssertEqual(book.admission(forRequester: "a"), .reuse(first))

    book.open(requesterKey: "a", id: AppletTabID.make())

    XCTAssertEqual(book.entries.count, 1)
    XCTAssertEqual(book.selected, first)
    XCTAssertTrue(book.entry(first)?.isOpen == true)
  }

  /// Catches a pane that accepts more open forms than its cap, and one that counts resolved tabs
  /// against a newcomer, which "A resolved tab never counts toward the cap" forbids.
  func testOnlyOpenFormsCountAgainstTheCap() {
    var book = QuestionsBook(cap: 2)
    let first = open(&book, "a")
    _ = open(&book, "b")

    XCTAssertEqual(book.admission(forRequester: "c"), .refused(.paneFull))

    book.resolve(first)

    XCTAssertEqual(book.admission(forRequester: "c"), .new(evicting: first))
  }

  /// Catches the wrong tab giving way. The oldest resolved tab that is not selected goes first,
  /// and the selected one goes only when it is the only resolved tab.
  func testTheOldestUnselectedResolvedTabGivesWay() {
    var book = QuestionsBook(cap: 3)
    let a = open(&book, "a")
    let b = open(&book, "b")
    let c = open(&book, "c")

    book.resolve(b)
    book.resolve(a)
    book.select(b)

    XCTAssertEqual(book.admission(forRequester: "d"), .new(evicting: a))

    book.select(a)

    XCTAssertEqual(book.admission(forRequester: "d"), .new(evicting: b))

    book.resolve(c)
    book.select(c)

    XCTAssertEqual(book.admission(forRequester: "d"), .new(evicting: b))
  }

  func testTheSelectedTabGivesWayWhenItIsTheOnlyResolvedOne() {
    var book = QuestionsBook(cap: 2)
    let a = open(&book, "a")
    _ = open(&book, "b")

    book.resolve(a)
    book.select(a)

    XCTAssertEqual(book.admission(forRequester: "c"), .new(evicting: a))
  }

  /// Catches a close that selects nothing or the wrong neighbor. The tab that takes the closed
  /// tab's place is selected, as in the browser, and a close of an unselected tab keeps the
  /// selection.
  func testClosingTheSelectedTabSelectsTheTabInItsPlace() {
    var book = QuestionsBook()
    let a = open(&book, "a")
    let b = open(&book, "b")
    let c = open(&book, "c")

    book.select(b)
    book.remove(b)

    XCTAssertEqual(book.selected, c)

    book.remove(c)

    XCTAssertEqual(book.selected, a)

    let stranger = AppletTabID.make()

    book.select(a)
    book.remove(stranger)

    XCTAssertEqual(book.selected, a)

    book.remove(a)

    XCTAssertTrue(book.isEmpty)
    XCTAssertNil(book.selected)
  }

  func testResolvingATabTwiceIsRefused() {
    var book = QuestionsBook()
    let a = open(&book, "a")

    XCTAssertTrue(book.resolve(a))
    XCTAssertFalse(book.resolve(a))
  }
}
