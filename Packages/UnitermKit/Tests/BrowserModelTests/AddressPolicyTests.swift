import XCTest

@testable import BrowserModel

/// The address rule: loopback loads over HTTP, every other scheme-less address tries HTTPS, and a
/// typed scheme is kept and checked.
final class AddressPolicyTests: XCTestCase {
  private func url(_ text: String) -> URL { URL(string: text)! }

  /// Catches a loopback form that falls through to HTTPS, where a local dev server that does not
  /// speak TLS would fail. The cases are the four settled forms, with ports and paths.
  func testLoopbackAddressesWithoutASchemeLoadOverHTTP() {
    let cases: [(typed: String, loaded: String)] = [
      ("localhost", "http://localhost"),
      ("localhost:3000/x?y=1", "http://localhost:3000/x?y=1"),
      ("LOCALHOST:3000", "http://LOCALHOST:3000"),
      ("app.localhost", "http://app.localhost"),
      ("a.b.localhost:8080/p", "http://a.b.localhost:8080/p"),
      ("127.0.0.1", "http://127.0.0.1"),
      ("127.255.255.254:80", "http://127.255.255.254:80"),
      ("[::1]", "http://[::1]"),
      ("[::1]:3000/path", "http://[::1]:3000/path"),
      ("localhost.", "http://localhost."),
    ]

    for (typed, loaded) in cases {
      XCTAssertEqual(
        AddressPolicy.resolve(typed), .load(url(loaded), assumed: .http), typed)
    }
  }

  /// Catches a name that merely looks like loopback taking plain HTTP. Private ranges, shorthand
  /// IPv4, and names that start or end with the loopback words are all ordinary hosts, so they
  /// try HTTPS. The userinfo case checks that the host, not the text before an `@`, decides.
  func testEveryOtherSchemelessAddressTriesHTTPS() {
    let cases: [(typed: String, loaded: String)] = [
      ("example.com", "https://example.com"),
      ("example.com/path?q=1", "https://example.com/path?q=1"),
      ("192.168.1.1", "https://192.168.1.1"),
      ("10.0.0.1:8080", "https://10.0.0.1:8080"),
      ("128.0.0.1", "https://128.0.0.1"),
      ("126.255.255.255", "https://126.255.255.255"),
      ("127.1", "https://127.1"),
      ("127.0.0.1.example.com", "https://127.0.0.1.example.com"),
      ("localhost.example.com", "https://localhost.example.com"),
      ("notlocalhost.example", "https://notlocalhost.example"),
      ("mylocalhost.com", "https://mylocalhost.com"),
      ("[::2]", "https://[::2]"),
      ("nas.local", "https://nas.local"),
      ("devbox:8080", "https://devbox:8080"),
      ("localhost@example.com", "https://localhost@example.com"),
    ]

    for (typed, loaded) in cases {
      XCTAssertEqual(
        AddressPolicy.resolve(typed), .load(url(loaded), assumed: .https), typed)
    }
  }

  /// Catches an `@` trick that makes a remote host look local, so a page on a remote host would
  /// load over HTTP.
  func testTheHostAfterAnAtSignDecidesLoopback() {
    XCTAssertEqual(
      AddressPolicy.resolve("example.com@localhost:3000"),
      .load(url("http://example.com@localhost:3000"), assumed: .http))
  }

  /// Catches a typed scheme that is replaced, lowercased away from what the user typed, or loaded
  /// without a host.
  func testATypedSchemeIsKept() {
    XCTAssertEqual(
      AddressPolicy.resolve("http://example.com"),
      .load(url("http://example.com"), assumed: nil))
    XCTAssertEqual(
      AddressPolicy.resolve("  https://example.com/A  "),
      .load(url("https://example.com/A"), assumed: nil))
    XCTAssertEqual(
      AddressPolicy.resolve("HTTP://localhost:3000"),
      .load(url("HTTP://localhost:3000"), assumed: nil))
    XCTAssertEqual(AddressPolicy.resolve("about:blank"), .load(url("about:blank"), assumed: nil))
    XCTAssertEqual(AddressPolicy.resolve("http://"), .refused(.notAnAddress))
  }

  /// Catches a refused scheme that loads, in any letter case and with surrounding space. The same
  /// rule serves a restored address, so the source is a parameter.
  func testRefusedSchemesNeverResolveToALoad() {
    for source in [NavigationSource.typed, .restored, .controller] {
      XCTAssertEqual(AddressPolicy.resolve("file:///etc/hosts", source: source), .refused(.file))
      XCTAssertEqual(
        AddressPolicy.resolve(" \tJAVASCRIPT:alert(1)\n", source: source), .refused(.javascript))
      XCTAssertEqual(
        AddressPolicy.resolve("data:text/html,hi", source: source), .refused(.data))

      if source != .typed {
        XCTAssertEqual(
          AddressPolicy.resolve("mailto:a@example.com", source: source),
          .refused(.unsupported(scheme: "mailto")), "only typed text may hand off to an app")
      }
    }
  }

  /// Catches a typed address for another app that is refused outright, which would leave the user
  /// no way to open `mailto:`, and a non-typed source that hands off, which would let a stored or
  /// commanded address reach an app. `about:other` and `blob:` are not apps' to take.
  func testOnlyTypedTextHandsOffToAnApp() {
    XCTAssertEqual(
      AddressPolicy.resolve("mailto:a@example.com"), .handoff(url("mailto:a@example.com")))
    XCTAssertEqual(
      AddressPolicy.resolve("ssh://host.example"), .handoff(url("ssh://host.example")))
    XCTAssertEqual(AddressPolicy.resolve("tel:+15551234"), .handoff(url("tel:+15551234")))
    XCTAssertEqual(
      AddressPolicy.resolve("tel:5551234"), .load(url("https://tel:5551234"), assumed: .https),
      "digits after the colon are a port, whatever the word is")

    XCTAssertEqual(
      AddressPolicy.resolve("about:config"), .refused(.unsupported(scheme: "about")))
    XCTAssertEqual(
      AddressPolicy.resolve("blob:https://example.com/1"),
      .refused(.unsupported(scheme: "blob")))

    for source in [NavigationSource.restored, .controller, .page] {
      XCTAssertEqual(
        AddressPolicy.resolve("ssh://host.example", source: source),
        .refused(.unsupported(scheme: "ssh")), "\(source)")
    }
  }

  /// Catches a `host:port` that reads as a scheme, which would refuse a local dev server, and a real
  /// scheme that reads as a port.
  func testHostAndPortIsNotAScheme() {
    XCTAssertFalse(AddressClassifier.hasScheme("localhost:3000"))
    XCTAssertFalse(AddressClassifier.hasScheme("example.com:8080/path"))
    XCTAssertFalse(AddressClassifier.hasScheme("devbox:8080?x=1"))
    XCTAssertFalse(AddressClassifier.hasScheme("example.com"))
    XCTAssertFalse(AddressClassifier.hasScheme("[::1]:3000"))

    XCTAssertTrue(AddressClassifier.hasScheme("mailto:a@example.com"))
    XCTAssertTrue(AddressClassifier.hasScheme("http://example.com"))
    XCTAssertTrue(AddressClassifier.hasScheme("localhost://x"))
    XCTAssertTrue(AddressClassifier.hasScheme("javascript:alert(1)"))
  }

  /// Catches empty input that loads something, and text that is not an address loading or
  /// searching from a source that never searches. Only typed text searches.
  func testEmptyInputLoadsNothingAndOnlyTypedTextSearches() {
    XCTAssertEqual(AddressPolicy.resolve(""), .empty)
    XCTAssertEqual(AddressPolicy.resolve(" \n\t "), .empty)
    XCTAssertEqual(AddressPolicy.resolve("two words"), .search("two words"))
    XCTAssertEqual(AddressPolicy.resolve("example.com/a b"), .search("example.com/a b"))
    XCTAssertEqual(AddressPolicy.resolve("devbox"), .search("devbox"))

    for source in [NavigationSource.restored, .controller, .page] {
      XCTAssertEqual(
        AddressPolicy.resolve("two words", source: source), .refused(.notAnAddress), "\(source)")
      XCTAssertEqual(
        AddressPolicy.resolve("devbox", source: source), .refused(.notAnAddress), "\(source)")
    }
  }

  /// Catches a bare IPv6 literal that fails to load, or a control character that reaches a search
  /// or an address. A bare literal is bracketed. Control characters are refused with the same
  /// mark as any other text that is not an address.
  func testBareIPv6AndControlCharacters() {
    XCTAssertEqual(AddressPolicy.resolve("::1"), .load(url("http://[::1]"), assumed: .http))
    XCTAssertEqual(
      AddressPolicy.resolve("2001:db8::1"), .load(url("https://[2001:db8::1]"), assumed: .https))
    XCTAssertEqual(AddressPolicy.resolve("a\u{0}b.com"), .refused(.notAnAddress))
    XCTAssertEqual(AddressPolicy.resolve("a\u{1B}[0m"), .refused(.notAnAddress))
  }

  /// Catches Load over HTTP that downgrades an address the user typed with `https://`, or one
  /// that cannot reach plain HTTP for a scheme-less non-loopback address. The same function
  /// answers, with the override as its only difference.
  func testTheOverrideChangesOnlyAnAssumedScheme() {
    XCTAssertEqual(
      AddressPolicy.resolve("example.com/p", overridingToHTTP: true),
      .load(url("http://example.com/p"), assumed: .http))
    XCTAssertEqual(
      AddressPolicy.resolve("devbox:8080", overridingToHTTP: true),
      .load(url("http://devbox:8080"), assumed: .http))
    XCTAssertEqual(
      AddressPolicy.resolve("https://example.com", overridingToHTTP: true),
      .load(url("https://example.com"), assumed: nil), "an explicit https never downgrades")
    XCTAssertEqual(
      AddressPolicy.resolve("two words", overridingToHTTP: true), .search("two words"))
  }

  func testLoopbackHostsDirectly() {
    for host in ["localhost", "x.localhost", "127.0.0.1", "127.9.9.9", "::1", "[::1]", "LocalHost"]
    {
      XCTAssertTrue(AddressPolicy.isLoopback(host: host), host)
    }

    for host in ["", "example.com", "128.0.0.1", "::2", "0.0.0.0", "localhost.com", "1270.0.0.1"] {
      XCTAssertFalse(AddressPolicy.isLoopback(host: host), host)
    }
  }
}
