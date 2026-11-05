import CoreLocation
import GeoData
import MapKit

/// Names the place at a coordinate, at a scale, or gives nil when it has no name for it.
public typealias PlaceLookup = @MainActor (GeoCoordinate, PlaceScale) async -> String?

/// How much of a place's name the map shows, from how far out it is zoomed.
public enum PlaceScale: Equatable, Sendable {
  /// A country or region, such as "Japan".
  case country

  /// A city with its context, such as "Los Angeles, CA".
  case city

  /// A map that shows this much latitude or more names countries.
  static let countrySpan = 12.0

  init(_ span: GeoSpan) {
    self = span.latitudeDelta >= Self.countrySpan ? .country : .city
  }
}

/// Names the place at the center of the map, for the palette.
///
/// A name costs a request to Apple, so a move that cannot change the name asks nothing. A move
/// within a quarter of the view at the same scale keeps the last answer. A newer request replaces
/// an older one, and the older answer is dropped.
///
/// The name is never saved. A pane that is restored asks again, and a failed lookup, such as one
/// made offline, leaves no name.
@MainActor
final class PlaceNamer {
  /// Gets each new name, or nil when there is none.
  var onName: ((String?) -> Void)?

  private let lookup: PlaceLookup?

  private(set) var name: String?
  private(set) var pending: Task<Void, Never>?
  private var asked: (center: GeoCoordinate, span: GeoSpan, scale: PlaceScale)?

  init(lookup: PlaceLookup?) {
    self.lookup = lookup
  }

  /// Looks up the name for `region`, unless the last lookup already covers it.
  func regionShown(_ region: GeoRegion) {
    guard let lookup else { return }

    let scale = PlaceScale(region.span)

    if let asked, asked.scale == scale,
      abs(asked.center.latitude - region.center.latitude) < asked.span.latitudeDelta / 4,
      abs(asked.center.longitude - region.center.longitude) < asked.span.longitudeDelta / 4
    {
      return
    }

    asked = (region.center, region.span, scale)
    pending?.cancel()

    pending = Task { [weak self] in
      let found = await lookup(region.center, scale)

      guard !Task.isCancelled, let self else { return }

      self.pending = nil
      self.publish(found)
    }
  }

  /// Drops any lookup in flight. The owner calls it when the pane closes.
  func cancel() {
    pending?.cancel()
    pending = nil
    onName = nil
  }

  private func publish(_ found: String?) {
    let trimmed = found?.trimmingCharacters(in: .whitespacesAndNewlines)
    let next = trimmed?.isEmpty == false ? trimmed : nil

    guard next != name else { return }

    name = next
    onName?(next)
  }
}

extension MapViewerApplet {
  /// Apple's reverse geocoder, which the app gives each map pane. It sends the map's center to
  /// Apple, which already serves the map's tiles for that area. Open ocean and errors, such as
  /// being offline, give nil.
  public static let applePlaceNames: PlaceLookup = { center, scale in
    let location = CLLocation(latitude: center.latitude, longitude: center.longitude)

    guard let request = MKReverseGeocodingRequest(location: location) else { return nil }

    let items = try? await request.mapItems

    guard let place = items?.first?.addressRepresentations else { return nil }

    switch scale {
    case .country:
      return place.regionName

    case .city:
      return place.cityWithContext ?? place.cityName ?? place.regionName
    }
  }
}
