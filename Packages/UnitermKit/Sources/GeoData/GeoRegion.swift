import Foundation

/// A place on the globe in degrees.
public struct GeoCoordinate: Codable, Equatable, Sendable {
  public var latitude: Double
  public var longitude: Double

  public init(latitude: Double, longitude: Double) {
    self.latitude = latitude
    self.longitude = longitude
  }
}

/// How much of the globe a view covers, in degrees.
public struct GeoSpan: Codable, Equatable, Sendable {
  public var latitudeDelta: Double
  public var longitudeDelta: Double

  public init(latitudeDelta: Double, longitudeDelta: Double) {
    self.latitudeDelta = latitudeDelta
    self.longitudeDelta = longitudeDelta
  }
}

/// The part of the globe a map shows: a center and a span.
///
/// MapKit raises an Objective-C exception on a region it cannot take, so every region is checked
/// when it is made. The checks are the ones MapKit's own rules name: finite numbers, a center
/// latitude on the globe, a positive span, and latitude edges that stay between the poles. A
/// longitude is never rejected, since MapKit takes edges past the antimeridian.
public struct GeoRegion: Codable, Equatable, Sendable {
  public static let maxLatitudeDelta = 180.0
  public static let maxLongitudeDelta = 360.0

  public let center: GeoCoordinate
  public let span: GeoSpan

  /// Makes a region, or returns nil when the values cannot describe one. A center latitude outside
  /// -90 to 90, a value that is not finite, a span of zero or less, and a latitude edge past a pole
  /// all fail. A longitude is wrapped into -180 to 180, since a map panned across the antimeridian
  /// reports one outside it. A span past the whole globe is cut to it.
  public init?(center: GeoCoordinate, span: GeoSpan) {
    guard
      center.latitude.isFinite, center.longitude.isFinite, span.latitudeDelta.isFinite,
      span.longitudeDelta.isFinite, abs(center.latitude) <= 90, span.latitudeDelta > 0,
      span.longitudeDelta > 0
    else { return nil }

    let latitudeDelta = min(span.latitudeDelta, Self.maxLatitudeDelta)
    let halfSpan = latitudeDelta / 2

    guard center.latitude - halfSpan >= -90, center.latitude + halfSpan <= 90 else { return nil }

    self.center = GeoCoordinate(
      latitude: center.latitude, longitude: Self.wrap(longitude: center.longitude))
    self.span = GeoSpan(
      latitudeDelta: latitudeDelta,
      longitudeDelta: min(span.longitudeDelta, Self.maxLongitudeDelta))
  }

  private enum CodingKeys: String, CodingKey {
    case center
    case span
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let center = try container.decode(GeoCoordinate.self, forKey: .center)
    let span = try container.decode(GeoSpan.self, forKey: .span)

    guard let region = GeoRegion(center: center, span: span) else {
      throw DecodingError.dataCorruptedError(
        forKey: .center, in: container, debugDescription: "the region is out of range")
    }

    self = region
  }

  /// True when `other` differs by less than a map would show. A map that is set to a stored region
  /// reports a region a little off it, so an exact comparison would save the layout at every
  /// launch. The center must agree within a thousandth of the span, and the span within a
  /// thousandth of itself.
  public func isIndistinguishable(from other: GeoRegion) -> Bool {
    let tolerance = 0.001

    return abs(center.latitude - other.center.latitude) <= span.latitudeDelta * tolerance
      && abs(center.longitude - other.center.longitude) <= span.longitudeDelta * tolerance
      && abs(span.latitudeDelta - other.span.latitudeDelta) <= span.latitudeDelta * tolerance
      && abs(span.longitudeDelta - other.span.longitudeDelta) <= span.longitudeDelta * tolerance
  }

  private static func wrap(longitude: Double) -> Double {
    guard longitude < -180 || longitude > 180 else { return longitude }

    let shifted = (longitude + 180).truncatingRemainder(dividingBy: 360)

    return (shifted < 0 ? shifted + 360 : shifted) - 180
  }
}
