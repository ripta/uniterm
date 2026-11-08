import XCTest

@testable import BrowserModel

/// The rule that tells an address from a search. Each row is one input and its expected reading,
/// written from the proposal's text and not from the code. A row that fails names the input.
final class AddressClassifierTests: XCTestCase {
  private func check(
    _ rows: [(String, AddressInput)], file: StaticString = #filePath, line: UInt = #line
  ) {
    for (input, expected) in rows {
      XCTAssertEqual(
        AddressClassifier.classify(input), expected, input.debugDescription, file: file, line: line)
    }
  }

  /// Catches the settled examples reading wrongly. `devbox` searches, while `devbox/`,
  /// `localhost:3000`, and `devbox:8080` are addresses.
  func testTheProposalsExamples() {
    check([
      ("devbox", .search("devbox")),
      ("devbox/", .address("devbox/")),
      ("localhost:3000", .address("localhost:3000")),
      ("devbox:8080", .address("devbox:8080")),
      ("localhost", .address("localhost")),
      ("example.com", .address("example.com")),
      ("127.0.0.1", .address("127.0.0.1")),
      ("two words", .search("two words")),
    ])
  }

  /// Catches a word that an app registered as a URL scheme reading as that scheme when only digits
  /// follow the colon. A real scheme still reads as one.
  func testDigitsAfterTheColonAreAPortWhateverTheWordIs() {
    check([
      ("slack:8080", .address("slack:8080")),
      ("zoommtg:443/path", .address("zoommtg:443/path")),
      ("vnc:5900", .address("vnc:5900")),
      ("mailto:a@example.com", .address("mailto:a@example.com")),
      ("slack://channel", .address("slack://channel")),
      ("slack:open", .address("slack:open")),
    ])

    XCTAssertFalse(AddressClassifier.hasScheme("slack:8080"))
    XCTAssertTrue(AddressClassifier.hasScheme("slack:open"))
  }

  /// Catches input with a scheme, or ending in a slash, reading as a search. `http:` alone is an
  /// address the policy then refuses, not a search for the word.
  func testASchemeOrATrailingSlashIsAnAddress() {
    check([
      ("http:", .address("http:")),
      ("http://", .address("http://")),
      ("HTTPS://Example.com", .address("HTTPS://Example.com")),
      ("file:///etc/hosts", .address("file:///etc/hosts")),
      ("javascript:alert(1)", .address("javascript:alert(1)")),
      ("data:text/html,hi", .address("data:text/html,hi")),
      ("/usr/", .address("/usr/")),
      ("a/", .address("a/")),
    ])
  }

  /// Catches a space that does not make a search, and a scheme-like prefix that hides one. The
  /// space wins over a trailing slash and over `word:`. Only `scheme://` keeps spaced text an
  /// address, so a refused scheme with a space in its path is refused and not searched.
  func testASpaceMakesASearchUnlessTheTextStartsWithSchemeAndSlashes() {
    check([
      ("note: buy milk", .search("note: buy milk")),
      ("my notes/", .search("my notes/")),
      ("what is swift?", .search("what is swift?")),
      ("example.com is down", .search("example.com is down")),
      ("javascript: alert(1)", .search("javascript: alert(1)")),
      ("file:///Users/me/My Documents/a.txt", .address("file:///Users/me/My Documents/a.txt")),
      ("http://example.com/a b", .address("http://example.com/a b")),
    ])
  }

  /// Catches whitespace that survives into the query or hides an empty input. Edges are trimmed,
  /// and any run inside, newlines and tabs included, collapses to one space.
  func testWhitespaceIsTrimmedAndCollapsed() {
    check([
      ("  devbox  ", .search("devbox")),
      ("\n\texample.com\n", .address("example.com")),
      ("a  b\t\tc", .search("a b c")),
      ("line one\nline two", .search("line one line two")),
      ("a\r\nb", .search("a b")),
      ("   ", .empty),
      ("", .empty),
      ("\u{00A0}devbox\u{00A0}", .search("devbox")),
    ])
  }

  /// Catches control characters reaching a query or an address. A terminal escape or a NUL is
  /// neither. Newlines and tabs are whitespace and do not count.
  func testControlCharactersAreInvalid() {
    check([
      ("a\u{0}b", .invalid),
      ("\u{1B}[31mred", .invalid),
      ("example.com\u{7}", .invalid),
      ("two words\u{8}", .invalid),
      ("a\u{7F}b", .invalid),
    ])
  }

  /// Catches IP literals missed because they hold no dot. IPv6 with and without brackets, with
  /// and without a port, is an address. An IPv4 address holds dots already.
  func testIPAddressesAreAddresses() {
    check([
      ("[::1]", .address("[::1]")),
      ("[::1]:8080", .address("[::1]:8080")),
      ("[::1]/path", .address("[::1]/path")),
      ("::1", .address("::1")),
      ("fe80::1", .address("fe80::1")),
      ("2001:db8::1", .address("2001:db8::1")),
      ("127.0.0.1:8080", .address("127.0.0.1:8080")),
      ("10.0.0.1", .address("10.0.0.1")),
    ])

    XCTAssertTrue(AddressClassifier.isBareIPv6("::1"))
    XCTAssertFalse(AddressClassifier.isBareIPv6("devbox:80"))
    XCTAssertFalse(AddressClassifier.isBareIPv6("abc"))
  }

  /// Catches a name that merely resembles `localhost`, and a `localhost` with a path, port, or
  /// letter case that searches.
  func testLocalhostIsRecognisedByItsHostPart() {
    check([
      ("LocalHost", .address("LocalHost")),
      ("localhost/app", .address("localhost/app")),
      ("localhost?x=1", .address("localhost?x=1")),
      ("localhost#top", .address("localhost#top")),
      ("app.localhost", .address("app.localhost")),
      ("mylocalhost", .search("mylocalhost")),
      ("localhosts", .search("localhosts")),
    ])
  }

  /// Catches an `@` that decides the reading. The dot, or `host:port`, decides, as for any text.
  func testUserinfoDoesNotChangeTheRule() {
    check([
      ("user@host", .search("user@host")),
      ("user@host.com", .address("user@host.com")),
      ("user@host:8080", .address("user@host:8080")),
      ("me@example.com", .address("me@example.com")),
    ])
  }

  /// Catches a trailing dot, a leading dot, and a lone dot changing the reading. Each holds a dot,
  /// so each is an address, and the policy decides whether it loads.
  func testDotsAreAddressesWhereverTheyStand() {
    check([
      ("example.", .address("example.")),
      ("example.com.", .address("example.com.")),
      (".gitignore", .address(".gitignore")),
      (".", .address(".")),
      ("3.14", .address("3.14")),
    ])
  }

  /// Catches an encoded or non-ASCII input misread. Percent signs are text, not decoded. An
  /// internationalized name reads as an address by its dot, and one without a dot searches.
  func testPercentEncodingAndInternationalNames() {
    check([
      ("hello%20world", .search("hello%20world")),
      ("100%", .search("100%")),
      ("example.com/a%20b", .address("example.com/a%20b")),
      ("münchen.de", .address("münchen.de")),
      ("日本語.jp", .address("日本語.jp")),
      ("bücher", .search("bücher")),
      ("日本語", .search("日本語")),
      ("😀", .search("😀")),
      ("café:8080", .address("café:8080")),
    ])
  }

  /// Catches a query-only or fragment-only input, and a path with no dot, loading when the rule
  /// says search.
  func testOtherTextSearches() {
    check([
      ("?foo", .search("?foo")),
      ("#top", .search("#top")),
      ("/etc/hosts", .search("/etc/hosts")),
      ("devbox/notes", .search("devbox/notes")),
      ("swift", .search("swift")),
      ("c++", .search("c++")),
      ("what?", .search("what?")),
    ])
  }
}
