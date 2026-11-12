import CryptoKit
import Darwin
import Foundation

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

/// A key that signs controller descriptors. Where the private key lives is the key's own business,
/// so a key file now and the Keychain later both fit.
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

/// A private key in a file of its own: the 32 raw bytes, readable by its owner alone.
public enum ControllerKeyFile {
  /// Makes a new key at `path`. An existing file is never replaced, so a key cannot be lost by
  /// making another over it.
  public static func create(at path: String) throws -> InMemorySigningKey {
    let key = InMemorySigningKey()
    let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)

    guard descriptor >= 0 else {
      throw ControllerPackageError.io("cannot create the key \(path): \(errnoText())")
    }

    defer { close(descriptor) }

    let seed = key.seed
    let written = seed.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }

    guard written == seed.count, fsync(descriptor) == 0 else {
      let reason = errnoText()

      unlink(path)

      throw ControllerPackageError.io("cannot write the key \(path): \(reason)")
    }

    return key
  }

  /// Reads a key. A file another user owns, one that a group or others can read, a link, or one of
  /// the wrong size is refused.
  public static func load(from path: String) throws -> InMemorySigningKey {
    let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)

    guard descriptor >= 0 else {
      throw ControllerPackageError.io("cannot open the key \(path): \(errnoText())")
    }

    defer { close(descriptor) }

    var info = stat()

    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
      throw ControllerPackageError.io("the key \(path) is not a plain file")
    }

    guard info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
      throw ControllerPackageError.io(
        "the key \(path) must belong to you and be readable by you alone. Run chmod 600 on it.")
    }

    guard info.st_size == 32 else {
      throw ControllerPackageError.io("the key \(path) is not a uniterm signing key")
    }

    var seed = Data(count: 32)
    let read = seed.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, 32) }

    guard read == 32 else { throw ControllerPackageError.io("cannot read the key \(path)") }

    return try InMemorySigningKey(seed: seed)
  }
}

func errnoText() -> String {
  String(cString: strerror(errno))
}
