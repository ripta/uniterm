import CryptoKit
import Darwin
import Foundation
import Security

/// A controller's optional `controller.sig`: an Ed25519 signature over the exact bytes of its
/// `controller.json`.
///
/// The descriptor lists each packaged file's digest, so the signature covers the code. No Apple
/// developer certificate and no system trust root take part. A key is trusted only because the
/// user approved it, and continuity of that key is all a signature proves.
public struct ControllerSignature: Equatable, Sendable {
  public static let fileName = "controller.sig"

  /// The signature format this version reads and writes.
  public static let format = 1

  public static let maxBytes = 4 * 1024

  /// What is signed comes first, so a signature made for another purpose never verifies here.
  static let domain = Data("uniterm controller descriptor 1\n".utf8)

  /// The signer's raw 32-byte Ed25519 public key.
  public let publicKey: Data

  public let signature: Data

  public init(publicKey: Data, signature: Data) {
    self.publicKey = publicKey
    self.signature = signature
  }

  /// SHA-256 of the public key, as lowercase hex. Identity trust pins this with the controller ID.
  public var keyFingerprint: String { Data(SHA256.hash(data: publicKey)).hex }

  public static func parse(_ bytes: Data) throws -> ControllerSignature {
    let document: StrictJSON

    do {
      document = try StrictJSONReader.parse(bytes, maxBytes: maxBytes)
    } catch let error as StrictJSONError {
      throw ControllerPackageError.signature(error.description)
    }

    let fields: [String: StrictJSON]

    do {
      fields = try document.members(
        of: "the signature", required: ["format", "algorithm", "public-key", "signature"])
    } catch ControllerPackageError.malformed(let text) {
      throw ControllerPackageError.signature(text)
    }

    guard case .integer(let format) = fields["format"]!, format == Self.format else {
      throw ControllerPackageError.signature("format must be \(Self.format)")
    }

    guard case .string("ed25519") = fields["algorithm"]! else {
      throw ControllerPackageError.signature("algorithm must be ed25519")
    }

    guard case .string(let keyText) = fields["public-key"]!,
      let key = canonicalBase64(keyText), key.count == 32
    else {
      throw ControllerPackageError.signature("public-key must be 32 bytes of canonical base64")
    }

    guard case .string(let signatureText) = fields["signature"]!,
      let signature = canonicalBase64(signatureText), signature.count == 64
    else {
      throw ControllerPackageError.signature("signature must be 64 bytes of canonical base64")
    }

    return ControllerSignature(publicKey: key, signature: signature)
  }

  /// The file's bytes. A signer writes these, and `parse` reads them back unchanged.
  public func encoded() -> Data {
    Data(
      """
      {
        "format": \(Self.format),
        "algorithm": "ed25519",
        "public-key": "\(publicKey.base64EncodedString())",
        "signature": "\(signature.base64EncodedString())"
      }

      """.utf8)
  }

  /// Throws unless the signature verifies over `descriptor`, the exact bytes of the descriptor
  /// file.
  public func verify(descriptor: Data) throws {
    let key: Curve25519.Signing.PublicKey

    do {
      key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
    } catch {
      throw ControllerPackageError.signature("the public key is not an Ed25519 key")
    }

    guard key.isValidSignature(signature, for: Self.domain + descriptor) else {
      throw ControllerPackageError.signature(
        "the signature does not match controller.json, so the package was changed after it was "
          + "signed, or signed with another key")
    }
  }

  /// Signs the exact bytes of a descriptor.
  public static func sign(descriptor: Data, with key: any ControllerSigningKey) throws
    -> ControllerSignature
  {
    ControllerSignature(
      publicKey: key.publicKey, signature: try key.signature(for: domain + descriptor))
  }

  /// Base64 that decodes and encodes back to the same text, so one signature has one spelling.
  private static func canonicalBase64(_ text: String) -> Data? {
    guard let data = Data(base64Encoded: text), data.base64EncodedString() == text else {
      return nil
    }

    return data
  }
}

/// A key that signs controller descriptors. Where the private key lives is its store's business.
public protocol ControllerSigningKey: Sendable {
  /// The raw 32-byte Ed25519 public key.
  var publicKey: Data { get }

  func signature(for message: Data) throws -> Data
}

/// A key held in memory, for a signer that already has it.
public struct InMemorySigningKey: ControllerSigningKey {
  private let key: Curve25519.Signing.PrivateKey

  public init(seed: Data) throws {
    key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
  }

  public init() {
    key = Curve25519.Signing.PrivateKey()
  }

  /// The 32-byte private key. Only a key store reads it.
  var seed: Data { key.rawRepresentation }

  public var publicKey: Data { key.publicKey.rawRepresentation }

  public func signature(for message: Data) throws -> Data {
    try key.signature(for: message)
  }
}

/// Where signing keys live. Each key has a name the user chose. Making a key never replaces one,
/// and a missing key is an error, so signing never goes on with a different identity.
public protocol ControllerKeyStore: Sendable {
  /// Makes a new key under `name`. Throws when a key of that name exists.
  func create(named name: String) throws -> any ControllerSigningKey

  /// The key under `name`. Throws when there is none.
  func key(named name: String) throws -> any ControllerSigningKey
}

extension ControllerKeyStore {
  /// The longest key name, in UTF-8 bytes.
  public static var maxNameBytes: Int { 128 }

  /// A key name is printable text with no edge spaces.
  public static func checkName(_ name: String) throws {
    guard !name.isEmpty, name.utf8.count <= maxNameBytes,
      name.trimmingCharacters(in: .whitespaces) == name,
      name.unicodeScalars.allSatisfy({ !$0.properties.generalCategory.isControlOrFormat })
    else {
      throw ControllerPackageError.io(
        "a key name must be 1 to \(maxNameBytes) bytes of printable text with no edge spaces")
    }
  }
}

/// Keys as generic-password items in the user's login Keychain. Each item holds the 32-byte
/// Ed25519 private key, under the store's service and the key's name as its account.
public struct KeychainKeyStore: ControllerKeyStore {
  /// The service every uniterm signing key is filed under.
  public static let defaultService = "dev.uniterm.controller-signing-key"

  public let service: String

  public init(service: String = defaultService) {
    self.service = service
  }

  public func create(named name: String) throws -> any ControllerSigningKey {
    try Self.checkName(name)

    let key = InMemorySigningKey()
    let attributes: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: name,
      kSecAttrLabel as String: "uniterm controller signing key \(name)",
      kSecValueData as String: key.seed,
    ]

    let status = SecItemAdd(attributes as CFDictionary, nil)

    guard status != errSecDuplicateItem else {
      throw ControllerPackageError.io(
        "a signing key named \(name) is already in your login Keychain. uniterm never replaces a "
          + "key. Choose another name.")
    }

    guard status == errSecSuccess else {
      throw ControllerPackageError.io(
        "cannot add the key \(name) to your login Keychain: \(Self.text(status))")
    }

    return key
  }

  public func key(named name: String) throws -> any ControllerSigningKey {
    try Self.checkName(name)

    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: name,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)

    guard status != errSecItemNotFound else {
      throw ControllerPackageError.io(
        "no signing key named \(name) is in your login Keychain. uniterm signs with no other key "
          + "in its place, since another key is another identity. Make one with uniterm "
          + "controller keygen \(name).")
    }

    guard status == errSecSuccess, let seed = result as? Data else {
      throw ControllerPackageError.io(
        "cannot read the key \(name) from your login Keychain: \(Self.text(status))")
    }

    guard seed.count == 32 else {
      throw ControllerPackageError.io("the Keychain item \(name) is not a uniterm signing key")
    }

    return try InMemorySigningKey(seed: seed)
  }

  private static func text(_ status: OSStatus) -> String {
    (SecCopyErrorMessageString(status, nil) as String?) ?? "error \(status)"
  }
}

/// Keys held in memory, for tests and for a signer that already has its keys.
public final class InMemoryKeyStore: ControllerKeyStore, @unchecked Sendable {
  private let lock = NSLock()
  private var keys: [String: InMemorySigningKey]

  public init(keys: [String: InMemorySigningKey] = [:]) {
    self.keys = keys
  }

  public func create(named name: String) throws -> any ControllerSigningKey {
    try Self.checkName(name)

    return try lock.withLock {
      guard keys[name] == nil else {
        throw ControllerPackageError.io("a signing key named \(name) already exists")
      }

      let key = InMemorySigningKey()

      keys[name] = key

      return key
    }
  }

  public func key(named name: String) throws -> any ControllerSigningKey {
    try Self.checkName(name)

    return try lock.withLock {
      guard let key = keys[name] else {
        throw ControllerPackageError.io("no signing key named \(name)")
      }

      return key
    }
  }
}

func errnoText() -> String {
  String(cString: strerror(errno))
}
