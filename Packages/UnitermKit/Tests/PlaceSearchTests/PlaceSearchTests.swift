import AppKit
import GeoData
import XCTest

@testable import PlaceSearch

/// A searcher that answers from a script. It records each query and each region asked for, and
/// answers only when the test says so.
@MainActor
final class ScriptedSearcher: PlaceSearching {
  var onUpdate: ((Result<[PlaceSuggestion], PlaceSearchFailure>) -> Void)?
  var queries: [String] = []
  var regionsAsked: [PlaceSuggestion] = []
  var regionAnswer: Result<GeoRegion, PlaceSearchFailure> = .failure(.notFound)
  private(set) var cancelled = false

  func search(_ query: String) { queries.append(query) }

  func region(for suggestion: PlaceSuggestion) async -> Result<GeoRegion, PlaceSearchFailure> {
    regionsAsked.append(suggestion)
    return regionAnswer
  }

  func cancel() { cancelled = true }

  func answer(_ names: [(String, String)]) {
    onUpdate?(
      .success(names.enumerated().map { PlaceSuggestion(title: $1.0, subtitle: $1.1, token: $0) }))
  }
}

func losAngeles() -> GeoRegion {
  GeoRegion(
    center: GeoCoordinate(latitude: 34.05, longitude: -118.24),
    span: GeoSpan(latitudeDelta: 0.6, longitudeDelta: 0.6))!
}

/// The search field's rules: what is asked, what Return picks, and what each failure says.
@MainActor
final class PlaceSearchModelTests: XCTestCase {
  private func suggestion(_ title: String, _ token: Int) -> PlaceSuggestion {
    PlaceSuggestion(title: title, subtitle: "", token: token)
  }

  /// Catches a model that asks for blank text, or keeps old suggestions under an emptied field.
  func testOnlyANonBlankQueryAsks() {
    var model = PlaceSearchModel()

    XCTAssertFalse(model.setQuery("   "))
    XCTAssertEqual(model.status, .idle)
    XCTAssertTrue(model.setQuery("Los"))
    XCTAssertEqual(model.status, .searching)

    model.receive(.success([suggestion("Los Angeles", 0)]))
    XCTAssertFalse(model.setQuery(""))

    XCTAssertEqual(model.suggestions, [])
    XCTAssertNil(model.highlightedSuggestion)
    XCTAssertEqual(model.status, .idle)
  }

  /// Catches a Return that guesses. Before an answer nothing is highlighted, so Return picks
  /// nothing. The first suggestion is highlighted when it arrives, and Return picks what shows
  /// highlighted.
  func testReturnPicksOnlyWhatIsHighlighted() {
    var model = PlaceSearchModel()
    _ = model.setQuery("Springfield")

    XCTAssertNil(model.pick())

    model.receive(.success([suggestion("Springfield, IL", 0), suggestion("Springfield, OR", 1)]))
    XCTAssertEqual(model.highlightedSuggestion?.token, 0)

    XCTAssertTrue(model.move(by: 1))
    XCTAssertTrue(model.move(by: 1))
    XCTAssertEqual(model.highlightedSuggestion?.token, 1, "the highlight stops at the last")

    XCTAssertEqual(model.pick()?.token, 1)
    XCTAssertEqual(model.message, "Finding Springfield, OR\u{2026}")
    XCTAssertNil(model.pick(), "a second Return while finding picks nothing")
  }

  /// Catches a wrong or missing line for an empty answer and for each failure, and suggestions
  /// that arrive during a pick and replace the list the user picked from.
  func testEachOutcomeHasItsLine() {
    var model = PlaceSearchModel()
    _ = model.setQuery("qwzxv")

    model.receive(.success([]))
    XCTAssertEqual(model.status, .noMatch)
    XCTAssertEqual(model.message, "No places match. Try a city, an address, or a landmark.")

    model.receive(.failure(.offline))
    XCTAssertEqual(
      model.message, "Can\u{2019}t search places without a network connection.")

    model.receive(.success([suggestion("A", 0), suggestion("B", 1)]))
    _ = model.pick()
    model.receive(.success([suggestion("C", 0)]))
    XCTAssertEqual(model.suggestions.map(\.title), ["A", "B"])

    model.pickFailed(.notFound)
    XCTAssertEqual(model.suggestions.map(\.title), ["A", "B"])
    XCTAssertEqual(model.message, PlaceSearchFailure.notFound.message)
  }

  /// Catches an unbounded list. A long answer shows only the first few.
  func testTheListIsBounded() {
    var model = PlaceSearchModel()
    _ = model.setQuery("Main St")

    model.receive(.success((0..<20).map { suggestion("\($0)", $0) }))

    XCTAssertEqual(model.suggestions.count, PlaceSearchModel.maximumShown)
  }

  /// Catches a scale boundary that drifts. A view of 12 degrees of latitude or more names a
  /// country, and anything closer names a city.
  func testTheNameScaleFollowsTheSpan() {
    XCTAssertEqual(PlaceScale(GeoSpan(latitudeDelta: 40, longitudeDelta: 60)), .country)
    XCTAssertEqual(PlaceScale(GeoSpan(latitudeDelta: 12, longitudeDelta: 12)), .country)
    XCTAssertEqual(PlaceScale(GeoSpan(latitudeDelta: 11.9, longitudeDelta: 20)), .city)
  }

  /// Catches a network failure shown as "no match", which would send the user hunting for a
  /// spelling mistake. URL errors and MapKit's server errors read as offline, and MapKit's
  /// not-found reads as no match.
  func testErrorsSortIntoWhatTheUserCanActOn() {
    XCTAssertEqual(
      ApplePlaceSearch.failure(
        NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)),
      .offline)
    XCTAssertEqual(
      ApplePlaceSearch.failure(
        NSError(domain: "MKErrorDomain", code: 2)),
      .offline)
    XCTAssertEqual(
      ApplePlaceSearch.failure(NSError(domain: "MKErrorDomain", code: 4)), .notFound)
  }
}

/// The field as the launcher and the map use it: typing asks, keys move and pick, and Escape
/// empties before it leaves.
@MainActor
final class PlaceSearchViewTests: XCTestCase {
  private func makeView() -> (PlaceSearchView, ScriptedSearcher) {
    let searcher = ScriptedSearcher()
    let view = PlaceSearchView(searcher: searcher, placeholder: "Go to place")

    return (view, searcher)
  }

  private func key(_ view: PlaceSearchView, _ selector: Selector) -> Bool {
    view.control(view.field, textView: NSTextView(), doCommandBy: selector)
  }

  /// Catches a pick that never reaches the owner, or reaches it with another place's region.
  func testTypingThenReturnHandsOverThePickedRegion() async {
    let (view, searcher) = makeView()
    var picked: [(GeoRegion, String)] = []
    view.onPick = { picked.append(($0, $1.title)) }

    view.setQuery("Los Ang")
    XCTAssertEqual(searcher.queries, ["Los Ang"])

    searcher.answer([("Los Angeles", "California, United States"), ("Los Ángeles", "Chile")])
    searcher.regionAnswer = .success(losAngeles())

    XCTAssertTrue(key(view, #selector(NSResponder.insertNewline(_:))))
    await view.pendingPick?.value

    XCTAssertEqual(searcher.regionsAsked.map(\.title), ["Los Angeles"])
    XCTAssertEqual(picked.map(\.1), ["Los Angeles"])
    XCTAssertEqual(picked.first?.0, losAngeles())
  }

  /// Catches a failed lookup that closes the field or says nothing. The field stays with its
  /// suggestions and says why.
  func testAFailedPickStaysAndSaysWhy() async {
    let (view, searcher) = makeView()
    var picks = 0
    view.onPick = { _, _ in picks += 1 }

    view.setQuery("Kyoto")
    searcher.answer([("Kyoto", "Japan")])
    searcher.regionAnswer = .failure(.offline)

    _ = key(view, #selector(NSResponder.insertNewline(_:)))
    await view.pendingPick?.value

    XCTAssertEqual(picks, 0)
    XCTAssertEqual(view.model.suggestions.count, 1)
    XCTAssertEqual(view.model.message, PlaceSearchFailure.offline.message)
  }

  /// Catches keys the field swallows that its owner needs. Up and Down with no suggestions, Return
  /// on an empty field, and Escape on an empty field all go to the owner. Escape with text empties
  /// the field first.
  func testKeysTheFieldCannotUseGoToTheOwner() {
    let (view, searcher) = makeView()
    var moves: [Int] = []
    var submits = 0
    var escapes = 0
    view.onMoveOut = {
      moves.append($0)
      return true
    }
    view.onSubmitWithoutPlace = { submits += 1 }
    view.onEscapeEmpty = { escapes += 1 }

    _ = key(view, #selector(NSResponder.moveDown(_:)))
    _ = key(view, #selector(NSResponder.insertNewline(_:)))
    XCTAssertEqual(moves, [1])
    XCTAssertEqual(submits, 1)

    view.setQuery("Par")
    searcher.answer([("Paris", "France")])
    _ = key(view, #selector(NSResponder.moveDown(_:)))
    XCTAssertEqual(moves, [1], "a move through suggestions stays in the field")

    _ = key(view, #selector(NSResponder.cancelOperation(_:)))
    XCTAssertEqual(escapes, 0)
    XCTAssertEqual(view.model.query, "")
    XCTAssertEqual(view.field.stringValue, "")

    _ = key(view, #selector(NSResponder.cancelOperation(_:)))
    XCTAssertEqual(escapes, 1)
  }

  /// Catches a searcher left running after its field goes away.
  func testStopCancelsTheSearcher() {
    let (view, searcher) = makeView()

    view.stop()

    XCTAssertTrue(searcher.cancelled)
  }
}
