import AppletKit
import GeoData
import XCTest

@testable import MapViewerApplet

/// Answers place lookups from a script, and records each one. A held lookup waits until the test
/// releases it, so a test can finish lookups out of order.
@MainActor
final class ScriptedPlaces {
  var asked: [(center: GeoCoordinate, scale: PlaceScale)] = []
  var answer: String? = "Paris, France"
  private var held: [CheckedContinuation<String?, Never>] = []
  var holds = false

  var lookup: PlaceLookup {
    { [unowned self] center, scale in
      self.asked.append((center, scale))

      guard self.holds else { return self.answer }

      return await withCheckedContinuation { self.held.append($0) }
    }
  }

  func release(_ index: Int, with name: String?) {
    held[index].resume(returning: name)
  }
}

/// The palette's place name: when the map asks, at which scale, and what the pane publishes.
@MainActor
final class PlaceNamerTests: XCTestCase {
  private func region(_ latitude: Double, _ longitude: Double, _ delta: Double) -> GeoRegion {
    GeoRegion(
      center: GeoCoordinate(latitude: latitude, longitude: longitude),
      span: GeoSpan(latitudeDelta: delta, longitudeDelta: delta))!
  }

  private func show(_ applet: MapViewerApplet, _ region: GeoRegion) async {
    applet.content.onRegionShown?(region)
    await applet.places.pending?.value
  }

  /// Catches a scale boundary that drifts. A view of 12 degrees of latitude or more names a
  /// country, and anything closer names a city.
  func testTheScaleFollowsTheSpan() {
    XCTAssertEqual(PlaceScale(GeoSpan(latitudeDelta: 40, longitudeDelta: 60)), .country)
    XCTAssertEqual(PlaceScale(GeoSpan(latitudeDelta: 12, longitudeDelta: 12)), .country)
    XCTAssertEqual(PlaceScale(GeoSpan(latitudeDelta: 11.9, longitudeDelta: 20)), .city)
    XCTAssertEqual(PlaceScale(GeoSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)), .city)
  }

  /// Catches a name that never reaches the palette, or one written into the saved layout. The
  /// name rides on the pane's tab as a detail, the title stays the pane's own, and the
  /// description holds no trace of it.
  func testTheNameIsATabDetailAndIsNeverSaved() async throws {
    let places = ScriptedPlaces()
    let applet = MapViewerApplet(startDirectory: nil, placeNames: places.lookup)
    let host = RecordingHost()
    applet.host = host

    await show(applet, region(48.85, 2.35, 0.2))

    XCTAssertEqual(applet.publishedTabs.first.title, "Map")
    XCTAssertEqual(applet.publishedTabs.first.details, ["Paris, France"])
    XCTAssertEqual(host.tabChanges, 1)

    let saved = try XCTUnwrap(
      String(data: JSONEncoder().encode(applet.describe()), encoding: .utf8))
    XCTAssertFalse(saved.contains("Paris"), saved)
  }

  /// Catches a lookup for every small move, and a move or zoom that should change the name but
  /// asks nothing. A move within a quarter of the view keeps the name. A move further, or a zoom
  /// out to country scale, asks again, at the scale the view now shows.
  func testOnlyAMoveThatCanChangeTheNameAsks() async {
    let places = ScriptedPlaces()
    let applet = MapViewerApplet(startDirectory: nil, placeNames: places.lookup)

    await show(applet, region(48.85, 2.35, 0.2))
    await show(applet, region(48.86, 2.37, 0.2))
    await show(applet, region(48.85, 2.35, 0.1))

    XCTAssertEqual(places.asked.count, 1)
    XCTAssertEqual(places.asked.first?.scale, .city)

    await show(applet, region(48.85, 2.45, 0.2))

    XCTAssertEqual(places.asked.count, 2)

    places.answer = "France"
    await show(applet, region(48.85, 2.45, 20))

    XCTAssertEqual(places.asked.count, 3)
    XCTAssertEqual(places.asked.last?.scale, .country)
    XCTAssertEqual(applet.publishedTabs.first.details, ["France"])
  }

  /// Catches a slow answer that lands after a newer one and names a place the map left. The first
  /// lookup finishes last, and the pane keeps the second's name.
  func testAStaleAnswerIsDropped() async {
    let places = ScriptedPlaces()
    places.holds = true
    let applet = MapViewerApplet(startDirectory: nil, placeNames: places.lookup)

    applet.content.onRegionShown?(region(48.85, 2.35, 0.2))
    let first = applet.places.pending
    await Task.yield()

    applet.content.onRegionShown?(region(35.68, 139.69, 0.2))
    let second = applet.places.pending
    await Task.yield()

    XCTAssertEqual(places.asked.count, 2)

    places.release(1, with: "Tokyo, Japan")
    await second?.value
    places.release(0, with: "Paris, France")
    await first?.value

    XCTAssertEqual(applet.publishedTabs.first.details, ["Tokyo, Japan"])
  }

  /// Catches a name that outlives the place, such as after a move out to sea or a lookup made
  /// offline. An answer of nothing, or of blank text, clears the detail.
  func testNoAnswerClearsTheName() async {
    let places = ScriptedPlaces()
    let applet = MapViewerApplet(startDirectory: nil, placeNames: places.lookup)

    await show(applet, region(48.85, 2.35, 0.2))
    XCTAssertEqual(applet.publishedTabs.first.details, ["Paris, France"])

    places.answer = nil
    await show(applet, region(30, -40, 0.2))
    XCTAssertEqual(applet.publishedTabs.first.details, [])

    places.answer = "Paris, France"
    await show(applet, region(48.85, 2.35, 0.2))
    places.answer = "  "
    await show(applet, region(40, -40, 0.2))
    XCTAssertEqual(applet.publishedTabs.first.details, [])
  }

  /// Catches a map that names only places the user moved to. A restored region and a region the
  /// pane sets itself are shown too, and MapKit's settle after them asks for their name.
  func testASettleWithNoGestureStillAsks() async throws {
    let places = ScriptedPlaces()
    let applet = try MapViewerApplet(
      restoring: MapViewerDescription(region: region(48.85, 2.35, 0.2)).appletDescription(),
      placeNames: places.lookup)

    applet.content.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
    applet.content.layoutSubtreeIfNeeded()
    applet.content.mapView(applet.content.mapView, regionDidChangeAnimated: false)
    await applet.places.pending?.value

    XCTAssertEqual(places.asked.count, 1)
    XCTAssertEqual(places.asked.first?.center.latitude ?? 0, 48.85, accuracy: 0.05)
  }

  /// Catches a pane that asks with no lookup given, as every test and a tool would. Such a pane
  /// shows no name and makes no request.
  func testAPaneWithNoLookupAsksNothing() {
    let applet = MapViewerApplet(startDirectory: nil)

    applet.content.onRegionShown?(region(48.85, 2.35, 0.2))

    XCTAssertNil(applet.places.pending)
    XCTAssertEqual(applet.publishedTabs.first.details, [])
  }
}
