import GeoData

/// One place the search offers. The subtitle says where it is, which tells apart places that share
/// a name, such as Springfield in Illinois and Springfield in Oregon.
public struct PlaceSuggestion: Equatable, Sendable {
  public let title: String
  public let subtitle: String

  /// The searcher's own handle for the suggestion. It means nothing to anyone else.
  public let token: Int

  public init(title: String, subtitle: String, token: Int) {
    self.title = title
    self.subtitle = subtitle
    self.token = token
  }
}

/// Why a search or a lookup gave no place. The text is shown to the user.
public enum PlaceSearchFailure: Error, Equatable, Sendable {
  /// The network is down, so nothing can be searched.
  case offline

  /// The suggestion no longer names a place the service can find.
  case notFound

  /// Any other failure, with the service's own reason.
  case other(String)

  public var message: String {
    switch self {
    case .offline: return "Can\u{2019}t search places without a network connection."
    case .notFound: return "That place could not be found. Try another suggestion."
    case .other(let reason): return "The place search failed: \(reason)"
    }
  }
}

/// A source of place suggestions as the user types, and of the region a chosen one covers.
///
/// Each query replaces the one before it. Results for an older query never arrive after a newer
/// query's.
@MainActor
public protocol PlaceSearching: AnyObject {
  /// Gets the suggestions for the latest query, or why there are none.
  var onUpdate: ((Result<[PlaceSuggestion], PlaceSearchFailure>) -> Void)? { get set }

  /// Asks for suggestions for `query`. An empty query asks nothing.
  func search(_ query: String)

  /// The region the suggestion covers, such as a city's extent or an airport's grounds.
  func region(for suggestion: PlaceSuggestion) async -> Result<GeoRegion, PlaceSearchFailure>

  /// Stops any work in flight. Nothing arrives after it.
  func cancel()
}

/// Names the place at a coordinate, at a scale, or gives nil when it has no name for it.
public typealias PlaceLookup = @MainActor @Sendable (GeoCoordinate, PlaceScale) async -> String?

/// How much of a place's name to give, from how far out the map is zoomed.
public enum PlaceScale: Equatable, Sendable {
  /// A country or region, such as "Japan".
  case country

  /// A city with its context, such as "Los Angeles, CA".
  case city

  /// A map that shows this much latitude or more names countries.
  public static let countrySpan = 12.0

  public init(_ span: GeoSpan) {
    self = span.latitudeDelta >= Self.countrySpan ? .country : .city
  }
}

/// The place services a pane may use. Each one sends what the user typed or where the map looks to
/// a service, so a pane given none asks no one.
public struct PlaceServices: Sendable {
  /// Names the place at the map's center.
  public var names: PlaceLookup?

  /// Makes a searcher for one search field.
  public var search: (@MainActor @Sendable () -> any PlaceSearching)?

  public init(
    names: PlaceLookup? = nil, search: (@MainActor @Sendable () -> any PlaceSearching)? = nil
  ) {
    self.names = names
    self.search = search
  }

  /// No services. The pane shows no place name and offers no search.
  public static let none = PlaceServices()
}
