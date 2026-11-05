import CoreLocation
import GeoData
import MapKit

/// Place suggestions and regions from Apple Maps.
///
/// Each keystroke sends the field's text to Apple. The completer itself waits for typing to pause
/// and drops answers to queries it has replaced.
@MainActor
public final class ApplePlaceSearch: NSObject, PlaceSearching, MKLocalSearchCompleterDelegate {
  public var onUpdate: ((Result<[PlaceSuggestion], PlaceSearchFailure>) -> Void)?

  private let completer = MKLocalSearchCompleter()
  private var completions: [MKLocalSearchCompletion] = []

  /// The narrowest span a found region gets, so a street address does not zoom past the buildings.
  static let minimumSpan = 0.005

  override public init() {
    super.init()

    completer.delegate = self
    completer.resultTypes = [.address, .pointOfInterest]
  }

  public func search(_ query: String) {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !trimmed.isEmpty else {
      completer.cancel()
      return
    }

    completer.queryFragment = trimmed
  }

  public func cancel() {
    completer.cancel()
    onUpdate = nil
  }

  public nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
    MainActor.assumeIsolated {
      completions = self.completer.results
      onUpdate?(
        .success(
          completions.enumerated().map { index, completion in
            PlaceSuggestion(title: completion.title, subtitle: completion.subtitle, token: index)
          }))
    }
  }

  public nonisolated func completer(
    _ completer: MKLocalSearchCompleter, didFailWithError error: any Error
  ) {
    let failure = Self.failure(error)

    MainActor.assumeIsolated {
      completions = []

      if failure == .notFound {
        onUpdate?(.success([]))
      } else {
        onUpdate?(.failure(failure))
      }
    }
  }

  public func region(for suggestion: PlaceSuggestion) async -> Result<GeoRegion, PlaceSearchFailure>
  {
    guard completions.indices.contains(suggestion.token) else { return .failure(.notFound) }

    let search = MKLocalSearch(
      request: MKLocalSearch.Request(completion: completions[suggestion.token]))

    do {
      let response = try await search.start()
      let bounds = response.boundingRegion
      let span = GeoSpan(
        latitudeDelta: max(bounds.span.latitudeDelta, Self.minimumSpan),
        longitudeDelta: max(bounds.span.longitudeDelta, Self.minimumSpan))
      let center = GeoCoordinate(
        latitude: bounds.center.latitude, longitude: bounds.center.longitude)

      guard let region = GeoRegion(center: center, span: span) ?? GeoRegion.fitting([center]) else {
        return .failure(.notFound)
      }

      return .success(region)
    } catch {
      return .failure(Self.failure(error))
    }
  }

  /// Sorts a MapKit or network error into what the user can act on.
  nonisolated static func failure(_ error: any Error) -> PlaceSearchFailure {
    let error = error as NSError

    if error.domain == NSURLErrorDomain {
      return .offline
    }

    if error.domain == MKErrorDomain {
      switch MKError.Code(rawValue: UInt(error.code)) {
      case .placemarkNotFound: return .notFound
      case .serverFailure, .loadingThrottled: return .offline
      default: break
      }
    }

    return .other(error.localizedDescription)
  }
}

extension PlaceServices {
  /// Apple Maps for both names and search. The app gives this to each map pane and launcher.
  public static let apple = PlaceServices(
    names: { center, scale in await ApplePlaceNames.name(at: center, scale: scale) },
    search: { ApplePlaceSearch() })
}

/// Apple's reverse geocoder. It sends the map's center to Apple, which already serves the map's
/// tiles for that area. Open ocean and errors, such as being offline, give nil.
@MainActor
enum ApplePlaceNames {
  static func name(at center: GeoCoordinate, scale: PlaceScale) async -> String? {
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
