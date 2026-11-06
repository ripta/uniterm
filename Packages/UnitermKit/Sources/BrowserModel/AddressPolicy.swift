import Darwin
import Foundation

/// Which scheme the policy supplied for an address that had none.
public enum AssumedScheme: Sendable, Equatable {
  /// The address named a loopback host, which loads over HTTP because the traffic never leaves
  /// the machine.
  case http

  /// Any other host. The load tries HTTPS, and nothing downgrades without the user's action.
  case https
}

/// What the address bar does with what the user typed.
public enum AddressResolution: Sendable, Equatable {
  /// Load `url`. `assumed` is set when the policy chose the scheme, and nil when the user typed it.
  case load(URL, assumed: AssumedScheme?)

  /// The text is not an address, so it runs a search. Only typed text can search.
  case search(String)

  /// A typed address for another app. The applet asks the opener which app, if any, takes it.
  case handoff(URL)

  /// The address is one the browser never loads, such as `file:`.
  case refused(SchemeRefusal)

  /// Nothing was typed.
  case empty
}

/// Turns typed text, or any other scheme-less address, into the URL to load. One function applies
/// the rule, so a typed address, a stored one, and a retry over HTTP cannot disagree.
///
/// `AddressClassifier` first says whether the text is an address or a search. `localhost`,
/// `*.localhost`, `127.0.0.0/8`, and `[::1]` default to HTTP. Every other scheme-less address tries
/// HTTPS. An address with a scheme keeps it, and "Schemes" decides whether it loads.
public enum AddressPolicy {
  /// Resolves `input` for `source`. `overridingToHTTP` is the user's Load over HTTP action. It
  /// changes only a scheme-less address, so an address typed with `https://` never downgrades.
  public static func resolve(
    _ input: String, source: NavigationSource = .typed, overridingToHTTP: Bool = false
  ) -> AddressResolution {
    let text: String

    switch AddressClassifier.classify(input) {
    case .empty:
      return .empty

    case .invalid:
      return .refused(.notAnAddress)

    case .search(let query):
      return source == .typed ? .search(query) : .refused(.notAnAddress)

    case .address(let address):
      text = address
    }

    if AddressClassifier.hasScheme(text) {
      guard let url = URL(string: text) else { return .refused(.notAnAddress) }

      switch SchemePolicy.decide(url, source: source) {
      case .allow:
        if ["http", "https"].contains(url.scheme?.lowercased()),
          url.host(percentEncoded: false)?.isEmpty ?? true
        {
          return .refused(.notAnAddress)
        }

        return .load(url, assumed: nil)

      case .refuse(let refusal):
        if source == .typed, case .unsupported(let scheme) = refusal,
          AppHandoff.mayHandOff(scheme: scheme)
        {
          return .handoff(url)
        }

        return .refused(refusal)
      }
    }

    let bracketed = AddressClassifier.isBareIPv6(text) ? "[\(text)]" : text

    guard let host = host(ofSchemeless: bracketed) else { return .refused(.notAnAddress) }

    let assumed: AssumedScheme = overridingToHTTP || isLoopback(host: host) ? .http : .https
    let scheme = assumed == .http ? "http" : "https"

    guard let url = URL(string: "\(scheme)://\(bracketed)") else {
      return .refused(.notAnAddress)
    }

    return .load(url, assumed: assumed)
  }

  /// True when `host` is `localhost`, a name under `.localhost`, an IPv4 address in 127.0.0.0/8,
  /// or the IPv6 loopback address.
  ///
  /// An IPv4 address must be four decimal parts. A shorthand such as `127.1` is not loopback here,
  /// so it takes HTTPS, which is the safe way to be wrong. A name that merely starts with
  /// `localhost` or `127.` is not loopback.
  public static func isLoopback(host rawHost: String) -> Bool {
    var host = rawHost.lowercased()

    if host.hasPrefix("["), host.hasSuffix("]") {
      host = String(host.dropFirst().dropLast())
    }

    if host.hasSuffix(".") { host.removeLast() }

    guard !host.isEmpty else { return false }

    if host == "localhost" || host.hasSuffix(".localhost") { return true }

    var v4 = in_addr()

    if inet_pton(AF_INET, host, &v4) == 1 {
      return UInt32(bigEndian: v4.s_addr) >> 24 == 127
    }

    var v6 = in6_addr()

    if inet_pton(AF_INET6, host, &v6) == 1 {
      var loopback = in6_addr()
      inet_pton(AF_INET6, "::1", &loopback)

      return withUnsafeBytes(of: &v6) { a in
        withUnsafeBytes(of: &loopback) { b in a.elementsEqual(b) }
      }
    }

    return false
  }

  /// The host of an address with no scheme, read the way a URL would after `//`. Nil when there is
  /// no host to load.
  private static func host(ofSchemeless text: String) -> String? {
    guard let components = URLComponents(string: "//" + text), let host = components.host,
      !host.isEmpty
    else { return nil }

    return host
  }
}
