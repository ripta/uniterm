import Foundation
import Security

/// A self-signed TLS identity for the fixture server's TLS mode, and nothing else.
///
/// WARNING: the private key below is published test data. It protects nothing and signs nothing
/// real. The certificate names no real host. Its subject is `uniterm-test-fixture.invalid`, and it
/// lists `127.0.0.1` and `localhost` as alternative names. It is self-signed, so a client that
/// validates certificates refuses it, which is the point. The tests prove that the browser fails
/// closed, and no test installs a trust override to get past it.
///
/// The bundle is a PKCS#12 file made with `openssl req -x509 -newkey rsa:2048 -nodes -days 36500`
/// and `openssl pkcs12 -export`. It imports to memory only, so no keychain is touched.
enum SelfSignedFixtureIdentity {
  static let passphrase = "uniterm-fixture"

  private static let bundle = """
    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
    """

  /// The identity, or nil when the bundle does not import, which a test reports as a failure.
  static func make() -> SecIdentity? {
    let compact = bundle.filter { !$0.isWhitespace }

    guard let data = Data(base64Encoded: compact) else { return nil }

    var items: CFArray?
    let status = SecPKCS12Import(
      data as CFData,
      [
        kSecImportExportPassphrase as String: passphrase,
        kSecImportToMemoryOnly as String: true,
      ] as CFDictionary, &items)

    guard status == errSecSuccess,
      let entries = items as? [[String: Any]],
      let identity = entries.first?[kSecImportItemIdentity as String],
      CFGetTypeID(identity as CFTypeRef) == SecIdentityGetTypeID()
    else { return nil }

    return (identity as! SecIdentity)
  }
}
