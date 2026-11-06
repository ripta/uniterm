import Foundation

/// A failed main-frame load, reduced to what the rule needs. The error's text is not an input, so
/// a message that changes between macOS releases cannot change the rule.
public struct LoadFailure: Sendable, Equatable {
  public enum Kind: Sendable, Equatable {
    /// The server's certificate did not validate. It never offers plain HTTP, since the failure
    /// says someone may be answering for the host.
    case certificate

    /// The connection could not be made, or the server did not speak TLS. The one failure that
    /// can offer plain HTTP, and only for an address whose HTTPS the browser assumed.
    case unreachable

    /// Anything else, which reports as a warning.
    case other
  }

  public var domain: String
  public var code: Int

  /// Every TLS or stream status in the error and the errors nested under it, outermost first.
  public var underlyingStatuses: [Int]

  /// Whether the error, or one nested under it, carries the peer trust that failed. Only a
  /// certificate check produces one.
  public var hasPeerTrust: Bool

  public init(domain: String, code: Int, underlyingStatuses: [Int] = [], hasPeerTrust: Bool = false)
  {
    self.domain = domain
    self.code = code
    self.underlyingStatuses = underlyingStatuses
    self.hasPeerTrust = hasPeerTrust
  }

  public init(domain: String, code: Int, underlyingStatus: Int?, hasPeerTrust: Bool = false) {
    self.init(
      domain: domain, code: code, underlyingStatuses: underlyingStatus.map { [$0] } ?? [],
      hasPeerTrust: hasPeerTrust)
  }

  /// Reads the error WebKit reports for a failed main-frame load. Measured under `swift test`: a
  /// self-signed server is -1202 with the failed trust and an underlying `errSSLBadCert`, a plain
  /// listener answering HTTPS is -1200 with an underlying `errSSLClosedNoNotify`, and a closed
  /// port is -1004 with a refused connection. The nested errors are walked to a fixed depth, so a
  /// certificate sign at any level counts.
  public init(_ error: NSError) {
    var statuses: [Int] = []
    var trust = false
    var current: NSError? = error

    for _ in 0..<Self.maximumDepth {
      guard let level = current else { break }

      if let status = Self.status(of: level) { statuses.append(status) }

      if level.userInfo[Self.peerTrustKey] != nil { trust = true }

      current = level.userInfo[NSUnderlyingErrorKey] as? NSError
    }

    self.init(
      domain: error.domain, code: error.code, underlyingStatuses: statuses, hasPeerTrust: trust)
  }

  private static let maximumDepth = 8

  private static let peerTrustKey = "NSURLErrorFailingURLPeerTrustErrorKey"

  /// The `OSStatus` an error carries, from an `NSOSStatusErrorDomain` error or from the stream
  /// error keys CFNetwork sets.
  private static func status(of error: NSError) -> Int? {
    if error.domain == NSOSStatusErrorDomain { return error.code }

    return (error.userInfo["_kCFStreamErrorCodeKey"] as? Int)
      ?? (error.userInfo["_kCFNetworkCFStreamSSLErrorOriginalValue"] as? Int)
  }

  /// `NSURLErrorServerCertificateHasBadDate` through `NSURLErrorServerCertificateNotYetValid`.
  /// Client certificate codes are not here. They are not a failure to validate the server.
  private static let certificateCodes: ClosedRange<Int> = -1204 ... -1201

  /// The `errSSL` statuses that mean the certificate or its chain was rejected.
  private static let certificateStatuses: Set<Int> = [
    -9807, -9808, -9812, -9813, -9814, -9815, -9825, -9826, -9827, -9828, -9829, -9831, -9841,
    -9843,
  ]

  /// The `errSSL` statuses that say the peer closed the connection, which is what a server that
  /// does not speak TLS does to a handshake. `-1200` offers only with one of these.
  private static let closedConnectionStatuses: Set<Int> = [-9805, -9806, -9816]

  /// An allow-list, so a failure nobody classified can never reach the offer. A certificate sign
  /// anywhere sends the failure to the certificate pane first. Only a refused or lost connection,
  /// or a `-1200` that says the peer closed it, is unreachable.
  public var kind: Kind {
    guard domain == NSURLErrorDomain else { return .other }

    if Self.certificateCodes.contains(code) || hasPeerTrust { return .certificate }

    if underlyingStatuses.contains(where: Self.certificateStatuses.contains) {
      return .certificate
    }

    switch code {
    case NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost:
      return .unreachable

    case NSURLErrorSecureConnectionFailed:
      return underlyingStatuses.contains(where: Self.closedConnectionStatuses.contains)
        ? .unreachable : .other

    default:
      return .other
    }
  }
}
