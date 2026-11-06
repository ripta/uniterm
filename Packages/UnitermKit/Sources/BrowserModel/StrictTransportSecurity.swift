import Darwin
import Foundation

/// A `Strict-Transport-Security` header, read as RFC 6797 section 6.1 reads it.
public struct StrictTransportSecurity: Sendable, Equatable {
  public var maxAge: Int
  public var includeSubDomains: Bool

  /// The longest max-age kept, about 68 years. A header may ask for more, and the date arithmetic
  /// stays inside the range of a `Date`.
  public static let maximumAge = Int(Int32.max)

  public init(maxAge: Int, includeSubDomains: Bool) {
    self.maxAge = maxAge
    self.includeSubDomains = includeSubDomains
  }

  /// Nil when the header is not valid, which means the browser ignores it. A valid header has
  /// exactly one `max-age` with digits for its value, which may be quoted. A directive named twice
  /// invalidates the header. A directive this version does not know, such as `preload`, is
  /// ignored. Names are case-insensitive.
  public static func parse(_ header: String) -> StrictTransportSecurity? {
    var maxAge: Int?
    var includeSubDomains = false
    var seen: Set<String> = []

    for part in header.split(separator: ";", omittingEmptySubsequences: true) {
      let directive = part.trimmingCharacters(in: .whitespaces)

      guard !directive.isEmpty else { continue }

      let pieces = directive.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      let name = pieces[0].trimmingCharacters(in: .whitespaces).lowercased()

      guard !name.isEmpty else { return nil }

      guard seen.insert(name).inserted else { return nil }

      switch name {
      case "max-age":
        guard pieces.count == 2 else { return nil }

        var value = pieces[1].trimmingCharacters(in: .whitespaces)

        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
          value = String(value.dropFirst().dropLast())
        }

        guard !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }

        maxAge = Int(value).map { min($0, maximumAge) } ?? maximumAge

      case "includesubdomains":
        includeSubDomains = true

      default:
        continue
      }
    }

    guard let maxAge else { return nil }

    return StrictTransportSecurity(maxAge: maxAge, includeSubDomains: includeSubDomains)
  }
}

/// The hosts that have asked, over HTTPS, to be reached only over HTTPS.
///
/// WebKit enforces HSTS inside its own network process and has no public way to ask whether a host
/// is covered. The browser keeps this list itself, so the address bar can tell that a host under
/// HSTS never gets the offer of plain HTTP. It is a value with no clock of its own, so a test says
/// what time it is.
public struct HSTSList: Sendable, Equatable, Codable {
  public struct Entry: Sendable, Equatable, Codable {
    public var expires: Date
    public var includeSubDomains: Bool
  }

  /// The most hosts kept. A page picks only its own host name, so this bounds a site that serves
  /// many names, and the soonest to expire go first.
  public static let capacity = 2_048

  /// A move of an entry's expiry smaller than this is not recorded while the entry has at least
  /// this much life left.
  static let renewalSlack: TimeInterval = 3_600

  public private(set) var entries: [String: Entry] = [:]

  public init() {}

  /// Records a header seen on a main-frame HTTPS response from `host`. An invalid header changes
  /// nothing. A `max-age` of zero removes the host. An IP literal never records, since the
  /// protocol covers names only. Returns whether the list changed.
  @discardableResult
  public mutating func record(host rawHost: String, header: String, now: Date) -> Bool {
    guard let host = Self.normalized(rawHost), let policy = StrictTransportSecurity.parse(header)
    else { return false }

    let before = entries

    if policy.maxAge == 0 {
      entries[host] = nil
    } else {
      let expires = now.addingTimeInterval(TimeInterval(policy.maxAge))

      // A server sends the header on every response, so a live entry with a long term would move
      // by seconds each time and rewrite the file. Only a move of an hour or more, or an entry
      // with under an hour left, is worth the write.
      if let old = entries[host], old.includeSubDomains == policy.includeSubDomains,
        old.expires.timeIntervalSince(now) >= Self.renewalSlack,
        abs(expires.timeIntervalSince(old.expires)) < Self.renewalSlack
      {
        return false
      }

      entries[host] = Entry(expires: expires, includeSubDomains: policy.includeSubDomains)
    }

    prune(now: now)

    return entries != before
  }

  /// True when `host`, or a parent that asked for its subdomains too, has an unexpired entry.
  public func contains(host rawHost: String, now: Date) -> Bool {
    guard let host = Self.normalized(rawHost) else { return false }

    var candidate = Substring(host)
    var exact = true

    while true {
      if let entry = entries[String(candidate)], entry.expires > now,
        exact || entry.includeSubDomains
      {
        return true
      }

      guard let dot = candidate.firstIndex(of: ".") else { return false }

      candidate = candidate[candidate.index(after: dot)...]
      exact = false
    }
  }

  public mutating func removeAll() {
    entries = [:]
  }

  public mutating func prune(now: Date) {
    entries = entries.filter { $0.value.expires > now }

    while entries.count > Self.capacity,
      let soonest = entries.min(by: { $0.value.expires < $1.value.expires })?.key
    {
      entries[soonest] = nil
    }
  }

  /// The host in lowercase with no trailing dot, or nil for an empty name or an IP literal.
  static func normalized(_ rawHost: String) -> String? {
    var host = rawHost.lowercased()

    if host.hasSuffix(".") { host.removeLast() }

    guard !host.isEmpty else { return nil }

    var v4 = in_addr()
    var v6 = in6_addr()
    let bare =
      host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host

    if inet_pton(AF_INET, bare, &v4) == 1 || inet_pton(AF_INET6, bare, &v6) == 1 { return nil }

    return host
  }
}
