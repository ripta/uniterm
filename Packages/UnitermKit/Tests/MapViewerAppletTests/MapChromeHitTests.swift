import AppKit
import MapKit
import XCTest

@testable import MapViewerApplet

@MainActor
final class MapChromeHitTests: XCTestCase {
  /// Catches a class-name match that drifts from MapKit's real view tree. A press on the bare
  /// surface must stay a map click, and a press on any visible control of the map must not. This
  /// walks the tree MapKit builds in a window, so a renamed chrome view fails here. It cannot say
  /// what a later macOS names its views, and it does not cover the callout, which needs a pin
  /// selected on screen.
  func testMapKitsOwnChromeIsNotTheEmptyMap() throws {
    let applet = MapViewerApplet(startDirectory: nil)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
      backing: .buffered, defer: false)
    let view = applet.content
    let map = view.mapView

    window.contentView = view
    map.showsZoomControls = true
    map.showsCompass = true
    map.showsScale = true
    map.showsPitchControl = true
    view.layoutSubtreeIfNeeded()

    func hit(at point: NSPoint) -> NSView? {
      view.hitTest(window.contentView!.convert(map.convert(point, to: nil), from: nil))
    }

    let center = NSPoint(x: map.bounds.midX, y: map.bounds.midY)

    XCTAssertTrue(view.isEmptyMap(hit: hit(at: center)), "the map's center is not empty")

    var chrome: [NSView] = []

    func collect(_ v: NSView) {
      let name = String(describing: type(of: v))

      if ["MKAttributionLabel", "MKScaleView", "MKZoomControl", "MKPitchControl"].contains(name)
        || name.hasSuffix("CompassView")
      {
        chrome.append(v)
      }

      v.subviews.forEach(collect)
    }

    collect(map)

    XCTAssertGreaterThanOrEqual(chrome.count, 4, "MapKit built \(chrome.map { type(of: $0) })")

    for control in chrome {
      let point = control.convert(NSPoint(x: control.bounds.midX, y: control.bounds.midY), to: map)
      let found = hit(at: point)

      XCTAssertFalse(
        view.isEmptyMap(hit: found),
        "\(type(of: control)) counts as the empty map: \(String(describing: found))")
    }
  }
}
