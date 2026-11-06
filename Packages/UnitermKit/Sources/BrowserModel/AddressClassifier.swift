import Darwin
import Foundation

/// What typed text is: something to load, or something to search for.
public enum AddressInput: Sendable, Equatable {
  /// Nothing but whitespace.
  case empty

  /// Text to read as an address. The caller still checks that it forms a loadable one.
  case address(String)

  /// Text to send to the search engine, with each run of whitespace collapsed to one space.
  case search(String)

  /// Text that is neither, because it holds a control character. Pasted binary is not a query.
  case invalid
}

/// Tells an address from a search. It reads text only, so the rule tests without a web view.
///
/// Input with a scheme, or ending in `/`, is an address. Input with a space is a search. Other input
/// is an address when it holds a dot, is `localhost`, is an IP address, or has a `host:port` form.
/// Anything else searches.
///
/// Two refinements keep the rule from surprising anyone. A space wins over a trailing `/` and over
/// a bare `scheme:`, so `note: buy milk` and `my notes/` search. Only the unmistakable `scheme://`
/// start keeps spaced text an address, so a path with a space in a `file:` address is still
/// refused, not searched. Text that holds only digits after the colon is `host:port` even when
/// the word before the colon is a registered URL scheme.
public enum AddressClassifier {
  public static func classify(_ raw: String) -> AddressInput {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !text.isEmpty else { return .empty }

    guard !text.unicodeScalars.contains(where: isStrayControl) else { return .invalid }

    if text.contains(where: \.isWhitespace) {
      if startsWithSchemeAndSlashes(text) { return .address(text) }

      return .search(text.split(whereSeparator: \.isWhitespace).joined(separator: " "))
    }

    if text.hasSuffix("/") { return .address(text) }

    if isBareIPv6(text) { return .address(text) }

    if hasScheme(text) { return .address(text) }

    if hasHostAndPort(text) { return .address(text) }

    if text.contains(".") { return .address(text) }

    if isBracketedIPv6(text) { return .address(text) }

    if hostPart(of: text).lowercased() == "localhost" { return .address(text) }

    return .search(text)
  }

  /// True when the text starts with a scheme. `host:port` is not a scheme, even when the word
  /// before the colon names one. The text after the colon is a port when it is only digits, up to
  /// the path, query, or fragment.
  public static func hasScheme(_ text: String) -> Bool {
    guard let colon = text.firstIndex(of: ":") else { return false }

    guard isSchemeName(text[..<colon]) else { return false }

    let rest = text[text.index(after: colon)...]

    if rest.hasPrefix("//") { return true }

    return !isPortOnly(authority(of: rest))
  }

  /// True for a bare IPv6 literal, such as `::1`, which the address bar brackets before loading.
  public static func isBareIPv6(_ text: String) -> Bool {
    var v6 = in6_addr()

    return text.contains(":") && inet_pton(AF_INET6, text, &v6) == 1
  }

  private static func isBracketedIPv6(_ text: String) -> Bool {
    guard text.hasPrefix("["), let close = text.firstIndex(of: "]") else { return false }

    return isBareIPv6(String(text[text.index(after: text.startIndex)..<close]))
  }

  private static func hasHostAndPort(_ text: String) -> Bool {
    guard let colon = text.firstIndex(of: ":"), colon != text.startIndex else { return false }

    return isPortOnly(authority(of: text[text.index(after: colon)...]))
  }

  private static func startsWithSchemeAndSlashes(_ text: String) -> Bool {
    guard let colon = text.firstIndex(of: ":"), isSchemeName(text[..<colon]) else { return false }

    return text[text.index(after: colon)...].hasPrefix("//")
  }

  private static func isSchemeName(_ name: Substring) -> Bool {
    guard let first = name.first, first.isASCII, first.isLetter else { return false }

    return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) }
  }

  /// The text up to the path, query, or fragment.
  private static func authority(of rest: Substring) -> Substring {
    rest[..<(rest.firstIndex { "/?#".contains($0) } ?? rest.endIndex)]
  }

  private static func isPortOnly(_ text: Substring) -> Bool {
    !text.isEmpty && text.allSatisfy { $0.isASCII && $0.isNumber }
  }

  private static func hostPart(of text: String) -> String {
    String(text.prefix { !"/?#:".contains($0) })
  }

  private static func isStrayControl(_ scalar: Unicode.Scalar) -> Bool {
    scalar.properties.generalCategory == .control && !scalar.properties.isWhitespace
  }
}
