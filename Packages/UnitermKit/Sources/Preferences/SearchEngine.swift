import Foundation

/// Which search engine the browser's address bar uses for text that is not an address.
///
/// The list is fixed. Each engine takes one query parameter, so a search URL is a base address and
/// an encoded query, with no template to validate.
public enum SearchEngine: String, Sendable, CaseIterable {
  case duckDuckGo = "duckduckgo"
  case google
  case bing
  case ecosia
  case kagi

  public var displayName: String {
    switch self {
    case .duckDuckGo: return "DuckDuckGo"
    case .google: return "Google"
    case .bing: return "Bing"
    case .ecosia: return "Ecosia"
    case .kagi: return "Kagi"
    }
  }

  private var base: String {
    switch self {
    case .duckDuckGo: return "https://duckduckgo.com/?q="
    case .google: return "https://www.google.com/search?q="
    case .bing: return "https://www.bing.com/search?q="
    case .ecosia: return "https://www.ecosia.org/search?q="
    case .kagi: return "https://kagi.com/search?q="
    }
  }

  /// The address that runs `query`. Every byte outside the unreserved set is percent-encoded as
  /// UTF-8, so `&`, `=`, `+`, `#`, and `%` in the query cannot start another parameter or end the
  /// query. A space becomes `%20`.
  public func searchURL(for query: String) -> URL? {
    guard let encoded = query.addingPercentEncoding(withAllowedCharacters: Self.unreserved) else {
      return nil
    }

    return URL(string: base + encoded)
  }

  private static let unreserved = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}

extension SettingKey where Value == SearchEngine {
  public static var searchEngine: SettingKey<SearchEngine> {
    SettingKey(name: "searchEngine", defaultValue: .duckDuckGo)
  }
}
