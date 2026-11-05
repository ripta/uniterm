import Foundation

extension GeoRegion {
  /// The smallest span a fitted region takes, so a single pin does not zoom to the street.
  public static let minimumFittedSpan = 0.02

  /// A region that shows every coordinate with some margin, or nil for no coordinates.
  ///
  /// The box is the plain minimum and maximum of the latitudes and the longitudes, so a set that
  /// straddles the antimeridian fits as the wide box that spans the globe the long way. The center
  /// is moved off a pole when the padded box would pass it.
  public static func fitting(_ coordinates: [GeoCoordinate]) -> GeoRegion? {
    guard let first = coordinates.first else { return nil }

    var south = first.latitude
    var north = first.latitude
    var west = first.longitude
    var east = first.longitude

    for coordinate in coordinates {
      south = min(south, coordinate.latitude)
      north = max(north, coordinate.latitude)
      west = min(west, coordinate.longitude)
      east = max(east, coordinate.longitude)
    }

    let latitudeDelta = min(max((north - south) * 1.3, minimumFittedSpan), maxLatitudeDelta)
    let longitudeDelta = min(max((east - west) * 1.3, minimumFittedSpan), maxLongitudeDelta)
    let half = latitudeDelta / 2
    let latitude = min(max((north + south) / 2, -90 + half), 90 - half)

    return GeoRegion(
      center: GeoCoordinate(latitude: latitude, longitude: (east + west) / 2),
      span: GeoSpan(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta))
  }
}
