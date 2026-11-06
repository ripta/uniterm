import Foundation
import XCTest

@testable import BrowserModel

/// The rule that decides which failed loads may offer plain HTTP. The rows marked measured come from
/// real loads under `swift test`, and the applet tests repeat those loads against the two fixture
/// modes. The rest are the codes WebKit and CFNetwork document.
final class LoadFailureTests: XCTestCase {
  private func failure(
    _ code: Int, underlying: Int? = nil, trust: Bool = false, domain: String = NSURLErrorDomain
  ) -> LoadFailure {
    LoadFailure(domain: domain, code: code, underlyingStatus: underlying, hasPeerTrust: trust)
  }

  /// Catches a certificate failure that can reach the offer. Each row is a way a server's
  /// certificate fails to validate. The first is measured against the self-signed fixture. The
  /// `-1200` rows are the ambiguous code, which carries a certificate status or a failed trust
  /// when the failure is the certificate.
  func testCertificateFailuresNeverOfferHTTP() {
    let rows: [(String, LoadFailure)] = [
      (
        "measured: self-signed, -1202 with trust and errSSLBadCert",
        failure(-1202, underlying: -9808, trust: true)
      ),
      ("bad date", failure(-1201)),
      ("untrusted", failure(-1202)),
      ("unknown root", failure(-1203)),
      ("not yet valid", failure(-1204)),
      ("-1200 with a failed trust", failure(-1200, trust: true)),
      ("-1200 with errSSLXCertChainInvalid", failure(-1200, underlying: -9807)),
      ("-1200 with errSSLCertExpired", failure(-1200, underlying: -9814)),
      ("-1200 with errSSLHostNameMismatch", failure(-1200, underlying: -9843)),
      ("-1200 with errSSLPeerUnknownCA", failure(-1200, underlying: -9831)),
      ("-1004 with a failed trust", failure(-1004, trust: true)),
    ]

    for (name, row) in rows {
      XCTAssertEqual(row.kind, .certificate, name)
    }
  }

  /// Catches a connection failure that does not offer. A closed port and a server that does not
  /// speak TLS are the two settled cases, and both are measured. Connection lost covers a server
  /// that resets the handshake.
  func testAnUnreachableServerOffersHTTP() {
    let rows: [(String, LoadFailure)] = [
      ("measured: closed port, -1004 with a refused connection", failure(-1004, underlying: 61)),
      (
        "measured: plain listener, -1200 with errSSLClosedNoNotify",
        failure(-1200, underlying: -9816)
      ),
      ("-1200 with errSSLClosedAbort", failure(-1200, underlying: -9806)),
      ("-1200 with errSSLClosedGraceful", failure(-1200, underlying: -9805)),
      ("connection lost", failure(-1005)),
    ]

    for (name, row) in rows {
      XCTAssertEqual(row.kind, .unreachable, name)
    }
  }

  /// Catches a failure that is neither, offering HTTP. A timeout, a missing host, no network, a
  /// bad URL, a client certificate request, and a failure in another domain are all plain
  /// warnings.
  func testOtherFailuresOfferNothing() {
    let rows: [(String, LoadFailure)] = [
      ("-1200 with no status", failure(-1200)),
      (
        "-1200 with a handshake failure that is not a certificate",
        failure(-1200, underlying: -9824)
      ),
      ("-1200 with a status nobody classified", failure(-1200, underlying: -9999)),
      ("-1200 with no status", failure(-1200)),
      (
        "-1200 with a handshake failure that is not a certificate",
        failure(-1200, underlying: -9824)
      ),
      ("-1200 with a status nobody classified", failure(-1200, underlying: -9999)),
      ("timed out", failure(-1001)),
      ("cannot find host", failure(-1003)),
      ("not connected", failure(-1009)),
      ("bad URL", failure(-1000)),
      ("client certificate rejected", failure(-1205)),
      ("client certificate required", failure(-1206)),
      ("cancelled", failure(-999)),
      ("WebKit interrupted load", failure(102, domain: "WebKitErrorDomain")),
      ("a POSIX error with a TLS code", failure(-1200, domain: NSPOSIXErrorDomain)),
      ("a certificate code in another domain", failure(-1202, domain: "WebKitErrorDomain")),
    ]

    for (name, row) in rows {
      XCTAssertEqual(row.kind, .other, name)
    }
  }

  /// Catches the adapter reading a real error's fields wrongly. The errors are built the way the
  /// measured ones arrive, with the underlying error nested and the trust under the userInfo key.
  func testTheAdapterReadsAnErrorTheWayWebKitBuildsIt() {
    let selfSigned = NSError(
      domain: NSURLErrorDomain, code: -1202,
      userInfo: [
        NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: -9808),
        "NSURLErrorFailingURLPeerTrustErrorKey": "trust",
      ])
    let plain = NSError(
      domain: NSURLErrorDomain, code: -1200,
      userInfo: [NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: -9816)])
    let closed = NSError(
      domain: NSURLErrorDomain, code: -1004,
      userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: 61)])

    XCTAssertEqual(
      LoadFailure(selfSigned),
      LoadFailure(
        domain: NSURLErrorDomain, code: -1202, underlyingStatus: -9808, hasPeerTrust: true))
    XCTAssertEqual(
      LoadFailure(plain),
      LoadFailure(
        domain: NSURLErrorDomain, code: -1200, underlyingStatus: -9816, hasPeerTrust: false))
    XCTAssertEqual(
      LoadFailure(closed),
      LoadFailure(
        domain: NSURLErrorDomain, code: -1004, underlyingStatus: nil, hasPeerTrust: false),
      "a POSIX status is not a TLS status")
    XCTAssertEqual(LoadFailure(selfSigned).kind, .certificate)
    XCTAssertEqual(LoadFailure(plain).kind, .unreachable)
    XCTAssertEqual(LoadFailure(closed).kind, .unreachable)
  }

  /// Catches a certificate sign hidden below the first nested error, which a one-level read would
  /// miss and offer HTTP for. The trust and the status each sit two levels down, and a stream key
  /// carries a closed-connection status the same way.
  func testTheAdapterWalksNestedErrors() {
    let deepTrust = NSError(
      domain: NSURLErrorDomain, code: -1200,
      userInfo: [
        NSUnderlyingErrorKey: NSError(
          domain: NSPOSIXErrorDomain, code: 1,
          userInfo: [
            NSUnderlyingErrorKey: NSError(
              domain: "Other", code: 2,
              userInfo: ["NSURLErrorFailingURLPeerTrustErrorKey": "trust"])
          ])
      ])
    let deepStatus = NSError(
      domain: NSURLErrorDomain, code: -1200,
      userInfo: [
        NSUnderlyingErrorKey: NSError(
          domain: "Other", code: 1,
          userInfo: [NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: -9807)])
      ])
    let streamKey = NSError(
      domain: NSURLErrorDomain, code: -1200, userInfo: ["_kCFStreamErrorCodeKey": -9816])

    XCTAssertEqual(LoadFailure(deepTrust).kind, .certificate)
    XCTAssertEqual(LoadFailure(deepStatus).kind, .certificate)
    XCTAssertEqual(LoadFailure(streamKey).kind, .unreachable)
  }
}
