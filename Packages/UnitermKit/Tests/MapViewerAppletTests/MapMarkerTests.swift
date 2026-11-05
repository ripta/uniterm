import AppKit
import GeoData
import MapKit
import Theme
import XCTest

@testable import MapViewerApplet

/// The markers as drawn: contrast of the glyph on its disc, re-tinting, and clustering.
@MainActor
final class MapMarkerTests: XCTestCase {
  private let scale = 4

  private struct Pixels {
    let width: Int
    let height: Int
    let data: [UInt8]

    func color(x: Int, y: Int) -> ThemeColor {
      let at = (y * width + x) * 4

      return ThemeColor(
        hex: UInt32(data[at]) << 16 | UInt32(data[at + 1]) << 8 | UInt32(data[at + 2]))
    }
  }

  /// Draws a view into an sRGB bitmap at four times its size.
  private func render(_ view: NSView) throws -> Pixels {
    let width = Int(view.bounds.width) * scale
    let height = Int(view.bounds.height) * scale
    var data = [UInt8](repeating: 0, count: width * height * 4)

    try data.withUnsafeMutableBytes { buffer in
      let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
      let context = try XCTUnwrap(
        CGContext(
          data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: width * 4, space: space,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))

      context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))

      let graphics = NSGraphicsContext(cgContext: context, flipped: false)

      view.displayIgnoringOpacity(view.bounds, in: graphics)
    }

    return Pixels(width: width, height: height, data: data)
  }

  /// Reads the disc and the glyph out of a rendered marker. The disc is sampled left of the glyph,
  /// inside the disc. The glyph is the pixel in the disc's middle that differs most from the disc.
  private func sample(_ pixels: Pixels, side: Double) -> (disc: ThemeColor, glyph: ThemeColor) {
    let middle = pixels.height / 2
    let centerX = pixels.width / 2
    let disc = pixels.color(x: centerX - Int(0.3 * side * Double(scale)), y: middle)

    var glyph = disc
    var best = 0.0
    let reach = Int(0.2 * side * Double(scale))

    for y in (middle - reach)...(middle + reach) {
      for x in (centerX - reach)...(centerX + reach) {
        let candidate = pixels.color(x: x, y: y)
        let ratio = candidate.contrastRatio(with: disc)

        if ratio > best {
          best = ratio
          glyph = candidate
        }
      }
    }

    return (disc, glyph)
  }

  private func closeEnough(_ first: ThemeColor, _ second: ThemeColor) -> Bool {
    abs(Int(first.red) - Int(second.red)) <= 4 && abs(Int(first.green) - Int(second.green)) <= 4
      && abs(Int(first.blue) - Int(second.blue)) <= 4
  }

  private func marker(_ annotation: any MKAnnotation, in view: MapViewerView) throws
    -> MapMarkerView
  {
    try XCTUnwrap(view.mapView(view.mapView, viewFor: annotation) as? MapMarkerView)
  }

  // MARK: Contrast as rendered

  /// Catches a glyph that is unreadable as drawn, whatever the computed token contrast says. A
  /// single pin with a text glyph and a cluster with a count are drawn to a bitmap in both flavors
  /// on every accent. The disc pixel is the palette's disc, the glyph pixel is the palette's text,
  /// and the two reach 4.5:1. It cannot prove how MapKit composes the view on the map.
  func testGlyphsAndCountsReachFourPointFiveAsRendered() throws {
    let content = MapViewerView()

    for flavor in ThemeFlavor.allCases {
      let palette = ThemePalette(flavor: flavor)

      content.apply(palette)

      for accent in ThemeToken.accents {
        let pin = GeoPin(
          id: "p", coordinate: GeoCoordinate(latitude: 1, longitude: 1), label: "L",
          glyph: .text("M"))

        let members = (0..<12).map {
          MapPinAnnotation(
            pin: GeoPin(
              id: "\($0)", coordinate: GeoCoordinate(latitude: 1, longitude: 1), label: "L"),
            layer: "file", layerAccent: accent)
        }

        let views: [(MapMarkerView, Double)] = [
          (
            try marker(
              MapPinAnnotation(pin: pin, layer: "file", layerAccent: accent), in: content),
            MapMarkerView.pinSide
          ),
          (
            try marker(MKClusterAnnotation(memberAnnotations: members), in: content),
            MapMarkerView.clusterSide
          ),
        ]

        for (view, side) in views {
          let found = sample(try render(view), side: side)
          let context = "\(flavor) \(accent) \(view.reuseIdentifier ?? "")"

          XCTAssertTrue(closeEnough(found.disc, palette.pinDisc), "disc \(context)")
          XCTAssertTrue(closeEnough(found.glyph, palette.pinGlyph), "glyph \(context)")
          XCTAssertGreaterThanOrEqual(found.glyph.contrastRatio(with: found.disc), 4.5, context)
        }
      }
    }
  }

  /// Catches a body that is not the accent. The ring around the disc is drawn in the accent's color
  /// for the flavor.
  func testTheBodyIsTheAccent() throws {
    let content = MapViewerView()
    let pin = GeoPin(id: "p", coordinate: GeoCoordinate(latitude: 1, longitude: 1), label: "L")

    for flavor in ThemeFlavor.allCases {
      let palette = ThemePalette(flavor: flavor)

      content.apply(palette)

      let view = try marker(
        MapPinAnnotation(pin: pin, layer: "file", layerAccent: .teal), in: content)
      let pixels = try render(view)
      let ring = pixels.color(x: pixels.width / 2, y: 2 * scale)

      XCTAssertTrue(closeEnough(ring, palette[.teal]), "\(flavor)")
    }
  }

  // MARK: Re-tint

  /// Catches a theme switch that needs a reload. The same live views change color when the palette
  /// changes, for a pin and for a cluster, and a pin that names its accent keeps that accent.
  func testAThemeSwitchRetintsLiveMarkersWithoutAReload() throws {
    let content = MapViewerView()
    content.apply(.latte)

    let pin = MapPinAnnotation(
      pin: GeoPin(
        id: "p", coordinate: GeoCoordinate(latitude: 1, longitude: 1), label: "L", accent: .mauve),
      layer: "file", layerAccent: .blue)

    let cluster = MKClusterAnnotation(memberAnnotations: [pin])
    let pinView = try marker(pin, in: content)
    let clusterView = try marker(cluster, in: content)

    XCTAssertEqual(pinView.currentArt.body, ThemePalette.latte[.mauve])
    XCTAssertEqual(pinView.currentArt.disc, ThemePalette.latte[.base])
    XCTAssertEqual(clusterView.currentArt.body, ThemePalette.latte[.blue])
    XCTAssertEqual(clusterView.currentArt.count, 1)

    content.apply(.mocha)

    XCTAssertEqual(pinView.currentArt.body, ThemePalette.mocha[.mauve])
    XCTAssertEqual(pinView.currentArt.disc, ThemePalette.mocha[.crust])
    XCTAssertEqual(pinView.currentArt.mark, ThemePalette.mocha[.text])
    XCTAssertEqual(clusterView.currentArt.body, ThemePalette.mocha[.blue])
    XCTAssertEqual(clusterView.currentArt.disc, ThemePalette.mocha[.crust])
  }

  // MARK: Clusters and labels

  /// Catches pins of two layers that can share a cluster, and a pin whose label never shows. The
  /// clustering identifier is the layer name, so MapKit never merges two layers. The title is the
  /// label MapKit shows in the callout on selection.
  func testPinsClusterByLayerAndShowTheirLabel() throws {
    let content = MapViewerView()
    let pin = GeoPin(id: "p", coordinate: GeoCoordinate(latitude: 1, longitude: 1), label: "Cafe")

    let first = MapPinAnnotation(pin: pin, layer: "file", layerAccent: .blue)
    let second = MapPinAnnotation(pin: pin, layer: "other", layerAccent: .peach)

    let firstView = try marker(first, in: content)
    let secondView = try marker(second, in: content)

    XCTAssertEqual(firstView.clusteringIdentifier, "file")
    XCTAssertEqual(secondView.clusteringIdentifier, "other")
    XCTAssertTrue(firstView.canShowCallout)
    XCTAssertEqual(first.title, "Cafe")
  }

  /// Catches a symbol the system lacks that breaks the marker. The pin falls back to the default
  /// glyph and still draws.
  func testAMissingSymbolFallsBackToTheDefaultGlyph() throws {
    let content = MapViewerView()
    let pin = GeoPin(
      id: "p", coordinate: GeoCoordinate(latitude: 1, longitude: 1), label: "L",
      glyph: .symbol("no.such.symbol"))

    let view = try marker(
      MapPinAnnotation(pin: pin, layer: "file", layerAccent: .blue), in: content)
    let found = sample(try render(view), side: MapMarkerView.pinSide)

    XCTAssertGreaterThanOrEqual(found.glyph.contrastRatio(with: found.disc), 4.5)
  }
}
