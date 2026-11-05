import AppKit
import AppletKit
import GeoData
import MapKit
import StatusKit
import Theme
import XCTest

@testable import MapViewerApplet

/// Collects what an applet tells its pane.
@MainActor
final class RecordingHost: AppletHost {
  var posts: [(level: StatusLevel, text: String)] = []
  var changes = 0

  func applet(_ applet: any Applet, post level: StatusLevel, text: String) {
    posts.append((level, text))
  }

  func appletDidExit(_ applet: any Applet) {}

  func appletDidChange(_ applet: any Applet) { changes += 1 }

  func appletTabsDidChange(_ applet: any Applet) {}

  func applet(_ applet: any Applet, confirm request: AppletConfirmation) async -> Bool { false }

  func issueCloseStamp() -> UInt64 { 0 }
}

/// The applet through its public contract: styles, palette, region, restore, and describe.
@MainActor
final class MapViewerAppletTests: XCTestCase {
  private func region(_ latitude: Double, _ longitude: Double, _ delta: Double = 1) -> GeoRegion {
    GeoRegion(
      center: GeoCoordinate(latitude: latitude, longitude: longitude),
      span: GeoSpan(latitudeDelta: delta, longitudeDelta: delta))!
  }

  private func configurationName(_ applet: MapViewerApplet) -> String {
    switch applet.content.mapView.preferredConfiguration {
    case is MKHybridMapConfiguration: return "hybrid"
    case is MKImageryMapConfiguration: return "satellite"
    case is MKStandardMapConfiguration: return "standard"
    default: return "other"
    }
  }

  private func restore(_ description: MapViewerDescription) throws -> MapViewerApplet {
    try MapViewerApplet(restoring: description.appletDescription())
  }

  // MARK: Styles

  /// Catches a style command that does not reach the map, one that is not stored, or one that
  /// does not tell the pane. Each style maps to its MapKit configuration, the status bar names it,
  /// and a repeat of the same style does not rewrite the layout.
  func testEachStyleCommandSwitchesTheMapAndIsDescribed() throws {
    let applet = MapViewerApplet(startDirectory: nil)
    let host = RecordingHost()
    applet.host = host

    XCTAssertEqual(configurationName(applet), "standard")
    XCTAssertEqual(applet.segments.map(\.text), ["Standard"])

    let commands = Dictionary(
      uniqueKeysWithValues: MapViewerApplet.commandSet.commands.map { ($0.name, $0) })

    for (name, expected, label) in [
      ("style-satellite", "satellite", "Satellite"), ("style-hybrid", "hybrid", "Hybrid"),
      ("style-standard", "standard", "Standard"),
    ] {
      let before = host.changes

      try XCTUnwrap(commands[name]).run(applet)

      XCTAssertEqual(configurationName(applet), expected, name)
      XCTAssertEqual(applet.segments.map(\.text), [label], name)
      XCTAssertEqual(try MapViewerDescription.decode(applet.describe()).style.rawValue, expected)
      XCTAssertEqual(host.changes, before + 1, name)
    }

    let before = host.changes

    try XCTUnwrap(commands["style-standard"]).run(applet)

    XCTAssertEqual(host.changes, before)
  }

  /// Catches a stored style that does not come back as the map's configuration, and an unknown one
  /// that does not show the standard map.
  func testRestoringShowsTheStoredStyleAndAnUnknownOneShowsStandard() throws {
    for style in MapStyle.allCases {
      let applet = try restore(MapViewerDescription(style: style))

      XCTAssertEqual(configurationName(applet), style.rawValue)
    }

    let unknown = AppletDescription(
      type: "map-viewer", version: 1, payload: .object(["style": .string("terrain")]))
    let applet = try MapViewerApplet(restoring: unknown)

    XCTAssertEqual(configurationName(applet), "standard")
  }

  // MARK: Palette

  /// Catches a map that inherits its window's appearance, and a flavor that maps to the wrong
  /// look. Every flavor sets the map's own appearance, and a switch flips it with no relaunch.
  func testThePaletteSetsTheMapsAppearanceForEveryFlavor() {
    let applet = MapViewerApplet(startDirectory: nil)

    XCTAssertFalse(ThemeFlavor.allCases.isEmpty)

    for flavor in ThemeFlavor.allCases + ThemeFlavor.allCases.reversed() {
      applet.apply(ThemePalette(flavor: flavor))

      let name = applet.content.appearance?.name

      XCTAssertEqual(name, flavor.isDark ? .darkAqua : .aqua, "\(flavor)")
    }

    applet.apply(.mocha)
    XCTAssertEqual(applet.content.appearance?.name, .darkAqua)

    applet.apply(.latte)
    XCTAssertEqual(applet.content.appearance?.name, .aqua)
  }

  // MARK: Region

  /// Catches a region saved at every frame, a region the user moved that is not described, and a
  /// stored region that restores out of place. The delegate's settle is the only trigger, and a
  /// settle on the region already stored tells the pane nothing.
  func testASettledRegionIsDescribedOnceAndTellsThePane() throws {
    let applet = MapViewerApplet(startDirectory: nil)
    let host = RecordingHost()
    applet.host = host

    XCTAssertNil(try MapViewerDescription.decode(applet.describe()).region)

    let moved = region(10, 20, 2)
    applet.content.onRegionSettled?(moved)

    XCTAssertEqual(try MapViewerDescription.decode(applet.describe()).region, moved)
    XCTAssertEqual(host.changes, 1)

    applet.content.onRegionSettled?(moved)
    applet.content.onRegionSettled?(region(10.0001, 20.0001, 2))

    XCTAssertEqual(host.changes, 1)

    applet.content.onRegionSettled?(region(11, 20, 2))

    XCTAssertEqual(host.changes, 2)
  }

  /// Lays the pane out at a real size, as a window would.
  private func layOut(_ applet: MapViewerApplet, width: Double = 600, height: Double = 400) {
    applet.content.frame = NSRect(x: 0, y: 0, width: width, height: height)
    applet.content.layoutSubtreeIfNeeded()
  }

  /// Reports the region the map shows now, as MapKit's delegate does after a settle.
  private func settle(_ applet: MapViewerApplet) {
    applet.content.mapView(applet.content.mapView, regionDidChangeAnimated: false)
  }

  /// A move by the user: the gesture, then the map's own settle.
  private func move(_ applet: MapViewerApplet, toLatitude latitude: Double) {
    applet.content.noteUserGesture()
    applet.content.mapView.setRegion(
      MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: latitude, longitude: 2.35),
        span: MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.2)),
      animated: false)
    settle(applet)
  }

  /// Catches a user move that never reaches the pane, and a settle reported twice. A move reports
  /// once, with the region the map shows, and a settle with no gesture before it reports nothing.
  func testAMoveByTheUserIsReportedOnce() throws {
    let applet = MapViewerApplet(startDirectory: nil)
    let host = RecordingHost()
    applet.host = host

    layOut(applet)
    move(applet, toLatitude: 48.85)

    XCTAssertEqual(host.changes, 1)
    XCTAssertEqual(
      try XCTUnwrap(MapViewerDescription.decode(applet.describe()).region).center.latitude, 48.85,
      accuracy: 0.01)

    settle(applet)

    XCTAssertEqual(host.changes, 1)

    move(applet, toLatitude: 49.5)

    XCTAssertEqual(host.changes, 2)
  }

  /// Catches a restore, a resize, or MapKit's own default region that rewrites a pane nobody
  /// touched, and a gesture that goes unreported. MapKit reports a region after each of those, in
  /// any number, and none follows a gesture. Removing the gesture gate makes the first settle
  /// report a change.
  func testSettlesWithNoGestureAreIgnored() throws {
    let stored = region(35, 139, 0.4)
    let restored = try restore(MapViewerDescription(region: stored))
    let empty = MapViewerApplet(startDirectory: nil)
    let host = RecordingHost()
    restored.host = host
    empty.host = host

    for applet in [restored, empty] {
      layOut(applet)

      for _ in 0..<3 { settle(applet) }

      layOut(applet, width: 800, height: 500)
      settle(applet)
    }

    XCTAssertEqual(host.changes, 0)
    XCTAssertEqual(try MapViewerDescription.decode(restored.describe()).region, stored)
    XCTAssertNil(try MapViewerDescription.decode(empty.describe()).region)

    move(restored, toLatitude: 36)

    XCTAssertEqual(host.changes, 1)
  }

  /// Catches a restored region that matches the map already showing, where MapKit may report
  /// nothing. No flag waits for a report, so the user's first move still counts.
  func testARestoredRegionThatChangesNothingDoesNotSwallowTheFirstMove() throws {
    let applet = try restore(MapViewerDescription(region: region(35, 139, 0.4)))
    let host = RecordingHost()
    applet.host = host

    layOut(applet)
    applet.content.show(region: region(35, 139, 0.4))
    move(applet, toLatitude: 36)

    XCTAssertEqual(host.changes, 1)
  }

  // MARK: Describe

  /// Catches a describe that touches the disk or changes state. Two calls on an unchanged pane
  /// are equal, and the pane's folder is never read to answer, so a folder that does not exist
  /// still describes.
  func testDescribeReadsMemoryOnlyAndRepeats() {
    let applet = MapViewerApplet(startDirectory: "/uniterm-no-such-folder")

    XCTAssertEqual(applet.describe(), applet.describe())

    applet.content.onRegionSettled?(region(1, 2))
    applet.apply(.mocha)

    XCTAssertEqual(applet.describe(), applet.describe())
  }

  /// Catches a restore that changes the description. A reopen or a relaunch rebuilds the pane from
  /// its description, and the new pane describes itself the same way.
  func testARestoredPaneDescribesItselfAsItWasSaved() throws {
    let original = MapViewerDescription(
      startDirectory: "/work", region: region(51.5, -0.12, 0.3), style: .satellite,
      commandLayerCount: 3)
    let applet = try restore(original)

    XCTAssertEqual(try MapViewerDescription.decode(applet.describe()), original)
    XCTAssertEqual(applet.describe(), try original.appletDescription())
  }

  /// Catches a restore that runs anything. A description that names a file never reads it in
  /// this milestone, so a missing file restores as it was saved.
  func testRestoringNamesNoFileToRead() throws {
    let original = MapViewerDescription(
      startDirectory: "/work", path: "/uniterm-no-such-file.geojson", bookmark: Data([9]))
    let applet = try restore(original)

    XCTAssertEqual(try MapViewerDescription.decode(applet.describe()), original)
  }

  // MARK: Directory

  /// Catches an empty pane that loses its start directory, a start directory that no longer
  /// exists being reported, and an open file's folder losing to it.
  func testTheCurrentDirectoryIsTheFileFolderThenTheStartDirectory() throws {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("uniterm-map-\(UUID().uuidString)", isDirectory: true)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }

    XCTAssertEqual(MapViewerApplet(startDirectory: folder.path).currentDirectory, folder.path)
    XCTAssertNil(MapViewerApplet(startDirectory: folder.path + "/gone").currentDirectory)
    XCTAssertNil(MapViewerApplet(startDirectory: nil).currentDirectory)

    let reopened = try restore(MapViewerDescription(startDirectory: folder.path))

    XCTAssertEqual(reopened.currentDirectory, folder.path)

    let withFile = try restore(
      MapViewerDescription(startDirectory: "/", path: folder.path + "/places.geojson"))

    XCTAssertEqual(withFile.currentDirectory, folder.path)
  }

  // MARK: Failure

  /// Catches a map that fails to load and says nothing. The message shows in the pane and goes to
  /// the status bar, and a later successful load clears the banner.
  func testALoadFailureShowsAMessageInThePaneUntilTheMapLoads() {
    let applet = MapViewerApplet(startDirectory: nil)
    let host = RecordingHost()
    applet.host = host

    let error = NSError(
      domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet,
      userInfo: [NSLocalizedDescriptionKey: "The Internet connection appears to be offline."])

    applet.content.mapViewDidFailLoadingMap(applet.content.mapView, withError: error)

    XCTAssertTrue(applet.content.failure?.contains("could not load") == true)
    XCTAssertTrue(applet.content.failure?.contains("offline") == true)
    XCTAssertEqual(host.posts.map(\.level), [.warning])

    applet.content.mapViewDidFinishLoadingMap(applet.content.mapView)

    XCTAssertNil(applet.content.failure)
  }

  // MARK: Contract

  /// Catches an applet that claims to run something, which would make closing it ask first.
  func testTheMapIsNeverRunningSomethingAndClosesCleanly() {
    let applet = MapViewerApplet(startDirectory: nil)

    XCTAssertFalse(applet.isRunningSomething)
    XCTAssertEqual(applet.runningLabels, [])
    XCTAssertEqual(applet.typeID, "map-viewer")
    XCTAssertEqual(applet.title, "Map")

    applet.start()
    applet.detach()
    applet.reattach()
    applet.close()
    applet.content.onRegionSettled?(region(1, 1))
  }
}
