/// How the map draws the world.
///
/// The stored name is the raw value. A name this build does not know reads as the standard map, so
/// a style added by a newer build never makes a layout unreadable.
public enum MapStyle: String, CaseIterable, Codable, Sendable {
  case standard
  case satellite
  case hybrid

  public init(from decoder: any Decoder) throws {
    let name = try decoder.singleValueContainer().decode(String.self)

    self = MapStyle(rawValue: name) ?? .standard
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()

    try container.encode(rawValue)
  }
}
