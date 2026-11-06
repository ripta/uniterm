import Foundation
import XCTest

@testable import Preferences

@MainActor
final class SearchEngineTests: XCTestCase {
  private var suiteName = ""
  private var defaults: UserDefaults!

  override func setUp() async throws {
    suiteName = "uniterm.tests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
  }

  override func tearDown() async throws {
    defaults.removePersistentDomain(forName: suiteName)
  }

  /// Catches a list that drifts from the settled one, or a default that is not DuckDuckGo.
  func testTheListIsFixedAndDuckDuckGoIsTheDefault() {
    XCTAssertEqual(
      SearchEngine.allCases, [.duckDuckGo, .google, .bing, .ecosia, .kagi])
    XCTAssertEqual(
      SearchEngine.allCases.map(\.displayName),
      ["DuckDuckGo", "Google", "Bing", "Ecosia", "Kagi"])
    XCTAssertEqual(
      SettingsStore(defaults: defaults).reading(of: .searchEngine),
      .unset(fallback: .duckDuckGo))
  }

  /// Catches raw values that `defaults write` cannot reach, and a stored name that no longer
  /// names an engine. The reading keeps the stored text so Settings can say it was replaced.
  func testStoredNamesAreThePlainRawStringsAndAnUnknownOneIsInvalid() {
    let store = SettingsStore(defaults: defaults)

    store.set(.kagi, for: .searchEngine)
    XCTAssertEqual(defaults.string(forKey: "searchEngine"), "kagi")

    defaults.set("altavista", forKey: "searchEngine")
    XCTAssertEqual(
      store.reading(of: .searchEngine), .invalid(raw: "altavista", fallback: .duckDuckGo))
    XCTAssertEqual(store.value(of: .searchEngine), .duckDuckGo)
    XCTAssertEqual(defaults.string(forKey: "searchEngine"), "altavista", "a read never writes")
  }

  /// Catches an engine whose address or parameter name is wrong. The expected addresses are
  /// written out by hand from each engine's documented search address.
  func testEachEngineBuildsItsOwnSearchAddress() {
    let expected: [SearchEngine: String] = [
      .duckDuckGo: "https://duckduckgo.com/?q=swift",
      .google: "https://www.google.com/search?q=swift",
      .bing: "https://www.bing.com/search?q=swift",
      .ecosia: "https://www.ecosia.org/search?q=swift",
      .kagi: "https://kagi.com/search?q=swift",
    ]

    for engine in SearchEngine.allCases {
      XCTAssertEqual(engine.searchURL(for: "swift")?.absoluteString, expected[engine], "\(engine)")
    }
  }

  /// Catches a query that can add a parameter, end early, or lose text. Each expected string is
  /// the UTF-8 percent encoding written out by hand. A query with `&` and `=` must not start a
  /// second parameter, and `#` must not start a fragment.
  func testTheQueryIsPercentEncodedByteForByte() {
    let cases: [(query: String, encoded: String)] = [
      ("two words", "two%20words"),
      ("a&b=c", "a%26b%3Dc"),
      ("1+1", "1%2B1"),
      ("c# or f#", "c%23%20or%20f%23"),
      ("100%", "100%25"),
      ("hello%20world", "hello%2520world"),
      ("what?", "what%3F"),
      ("a/b", "a%2Fb"),
      ("café", "caf%C3%A9"),
      ("日本", "%E6%97%A5%E6%9C%AC"),
      ("😀", "%F0%9F%98%80"),
      ("keep-._~", "keep-._~"),
      ("quote\"s'", "quote%22s%27"),
      ("a\nb", "a%0Ab"),
    ]

    for (query, encoded) in cases {
      XCTAssertEqual(
        SearchEngine.google.searchURL(for: query)?.absoluteString,
        "https://www.google.com/search?q=" + encoded, query)
    }
  }

  /// Catches an encoded query that a URL parser reads back as more than one parameter.
  func testAnAmpersandInTheQueryStaysInOneParameter() throws {
    let url = try XCTUnwrap(SearchEngine.duckDuckGo.searchURL(for: "a&b=c#d"))
    let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)

    XCTAssertEqual(items, [URLQueryItem(name: "q", value: "a&b=c#d")])
    XCTAssertNil(url.fragment)
  }
}
