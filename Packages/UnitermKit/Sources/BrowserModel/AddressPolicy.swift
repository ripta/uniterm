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

  /// The address is one the browser never loads, such as `file:`.
  case refused(SchemeRefusal)

  /// Nothing was typed.
  case empty
}

/// Turns typed text, or any other scheme-less address, into the URL to load. One function applies
/// the rule, so a typed address and a stored one cannot disagree.
///
/// `localhost`, `*.localhost`, `127.0.0.0/8`, and `[::1]` default to HTTP. Every other scheme-less
/// address tries HTTPS. An address with a scheme keeps it, and "Schemes" decides whether it loads.
public enum AddressPolicy {
  public static func resolve(_ input: String, source: NavigationSource = .typed)
    -> AddressResolution
  {
    let text = input.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !text.isEmpty else { return .empty }

    guard !text.contains(where: \.isWhitespace) else { return .refused(.notAnAddress) }

    if hasScheme(text) {
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
        return .refused(refusal)
      }
    }

    guard let host = host(ofSchemeless: text) else { return .refused(.notAnAddress) }

    let assumed: AssumedScheme = isLoopback(host: host) ? .http : .https
    let scheme = assumed == .http ? "http" : "https"

    guard let url = URL(string: "\(scheme)://\(text)") else { return .refused(.notAnAddress) }

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

  /// True when the text starts with a scheme. `host:port` is not a scheme, even when the word
  /// before the colon names one. The text after the colon is a port when it is only digits, up to
  /// the path, query, or fragment.
  static func hasScheme(_ text: String) -> Bool {
    guard let colon = text.firstIndex(of: ":") else { return false }

    let name = text[..<colon]

    guard let first = name.first, first.isASCII, first.isLetter,
      name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) })
    else { return false }

    let rest = text[text.index(after: colon)...]

    if rest.hasPrefix("//") { return true }

    let authorityEnd = rest.firstIndex { "/?#".contains($0) } ?? rest.endIndex
    let port = rest[..<authorityEnd]

    return port.isEmpty || !port.allSatisfy { $0.isASCII && $0.isNumber }
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
