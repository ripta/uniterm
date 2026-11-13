import ControllerTestSupport
import CryptoKit
import Foundation
import XCTest

@testable import ControllerPackage

/// The descriptor and signature formats as the shared reader holds them. The app's admission and
/// the helper's signer and loader read through the same code, and their own suites hold the same
/// fixtures, so a reader that drifts fails in every place it is used.
final class ControllerDescriptorTests: XCTestCase {
  /// Catches a reader that misreads a field of the shared fixture, or computes a version digest
  /// over anything but the exact bytes.
  func testTheSharedFixtureReadsAsShasumAndTheSignerComputed() throws {
    let package = ControllerFixtures.package("janet-hello")
    let bytes = try Data(contentsOf: package.appendingPathComponent("controller.json"))
    let descriptor = try ControllerDescriptor.parse(bytes)

    XCTAssertEqual(descriptor.id, ControllerFixtures.Hello.id)
    XCTAssertEqual(descriptor.name, ControllerFixtures.Hello.name)
    XCTAssertEqual(descriptor.entryKind, .janet)
    XCTAssertEqual(descriptor.entryPath, ControllerFixtures.Hello.entry)
    XCTAssertEqual(descriptor.files.mapValues(\.hex), ControllerFixtures.Hello.files)
    XCTAssertEqual(descriptor.permissions, ControllerFixtures.Hello.permissions)
    XCTAssertEqual(descriptor.versionHex, ControllerFixtures.Hello.version)

    let signature = try Data(contentsOf: package.appendingPathComponent("controller.sig"))
    let verified = try VerifiedController(descriptorBytes: bytes, signatureBytes: signature)

    XCTAssertEqual(
      verified.identity,
      ControllerIdentity(
        controllerID: ControllerFixtures.Hello.id, version: ControllerFixtures.Hello.version,
        keyFingerprint: ControllerFixtures.Hello.keyFingerprint))
  }

  /// Catches a reader that accepts any of the shared bad descriptors, or refuses one for a reason
  /// other than its fault.
  func testEverySharedBadDescriptorIsRefusedForItsOwnFault() throws {
    for (name, reason) in ControllerFixtures.rejected {
      let bytes = try ControllerFixtures.descriptor(name)

      XCTAssertThrowsError(try ControllerDescriptor.parse(bytes), name) { error in
        XCTAssertTrue(
          "\(error)".contains(reason), "\(name): \(error) does not say \"\(reason)\"")
      }
    }
  }

  /// Catches a signature check that passes a descriptor changed after signing, one signed by
  /// another key, or a signature file whose fields were swapped.
  func testABadSignatureOrAnotherKeyNeverVerifies() throws {
    let package = ControllerFixtures.package("janet-hello")
    let bytes = try Data(contentsOf: package.appendingPathComponent("controller.json"))
    let signatureBytes = try Data(contentsOf: package.appendingPathComponent("controller.sig"))
    let signature = try ControllerSignature.parse(signatureBytes)

    XCTAssertNoThrow(try signature.verify(descriptor: bytes))

    var changed = bytes

    changed[changed.index(changed.startIndex, offsetBy: 40)] ^= 0x01

    XCTAssertThrowsError(try signature.verify(descriptor: changed))

    let other = InMemorySigningKey()
    let otherSignature = try ControllerSignature.sign(descriptor: bytes, with: other)

    XCTAssertNoThrow(try otherSignature.verify(descriptor: bytes))
    XCTAssertNotEqual(otherSignature.keyFingerprint, ControllerFixtures.Hello.keyFingerprint)

    let swapped = ControllerSignature(publicKey: other.publicKey, signature: signature.signature)

    XCTAssertThrowsError(try swapped.verify(descriptor: bytes))
  }

  /// Catches a package whose signature fails and that is read as unsigned instead, which would let
  /// anyone strip a broken signature's meaning and keep the files.
  func testAPresentSignatureThatFailsNeverFallsBackToUnsigned() throws {
    let bytes = try Data(
      contentsOf: ControllerFixtures.package("janet-hello").appendingPathComponent(
        "controller.json"))
    let other = try ControllerSignature.sign(
      descriptor: Data("{}".utf8), with: try ControllerFixtures.signingKey())

    XCTAssertThrowsError(
      try VerifiedController(descriptorBytes: bytes, signatureBytes: other.encoded()))
    XCTAssertThrowsError(
      try VerifiedController(descriptorBytes: bytes, signatureBytes: Data("not json".utf8)))
    XCTAssertNil(try VerifiedController(descriptorBytes: bytes, signatureBytes: nil).signature)
  }

  /// Catches a signer whose output the reader cannot read back, or reads with another key.
  func testTheSignersFileReadsBackWithTheFixtureKey() throws {
    let key = try ControllerFixtures.signingKey()
    let bytes = Data("synthetic descriptor bytes".utf8)
    let signature = try ControllerSignature.sign(descriptor: bytes, with: key)
    let read = try ControllerSignature.parse(signature.encoded())

    XCTAssertEqual(read, signature)
    XCTAssertEqual(read.publicKey.base64EncodedString(), ControllerFixtures.Hello.publicKeyBase64)
    XCTAssertEqual(read.keyFingerprint, ControllerFixtures.Hello.keyFingerprint)
    XCTAssertNoThrow(try read.verify(descriptor: bytes))
  }

  /// Catches base64 with two spellings, such as one with its padding dropped, which would give
  /// one signature two file forms.
  func testASignatureFileMustUseCanonicalBase64() throws {
    let text = """
      {"format": 1, "algorithm": "ed25519", "public-key": "\
      GjTE9SBNzwk+HDRp0PxFl+e6xqDoT2wvZfyLtkicUoQ", "signature": "AA=="}
      """

    XCTAssertThrowsError(try ControllerSignature.parse(Data(text.utf8))) { error in
      XCTAssertTrue("\(error)".contains("canonical base64"), "\(error)")
    }
  }

  /// Catches strict JSON that lets an escape, a surrogate, or a number spell a value two ways.
  func testStrictJSONRefusesAmbiguousSpellings() {
    let refused = [
      #"{"a": "\ud800"}"#, #"{"a": "\u0000"}"#, #"{"a": 01}"#, #"{"a": 1.0}"#, #"{"a": 1e2}"#,
      #"{"a": -1}"#, #"{"a": null}"#, #"{"a": "x"} x"#, #"[[[[[[[[[1]]]]]]]]]"#,
      "{\"a\": \"\u{01}\"}",
    ]

    for text in refused {
      XCTAssertThrowsError(try StrictJSONReader.parse(Data(text.utf8), maxBytes: 1024), text)
    }

    XCTAssertEqual(
      try StrictJSONReader.parse(Data(#"{"a": "😀", "b": [1, 23]}"#.utf8), maxBytes: 64),
      .object([("a", .string("\u{1F600}")), ("b", .array([.integer(1), .integer(23)]))]))
  }

  /// Catches a format 2 reader that drops a permission's version, reads a kind format 1 lacks in
  /// format 1, or reads the new kinds without their scope. Format 1 stays readable with its two
  /// kinds at version 1, so its approvals carry over.
  func testFormatTwoVersionsEveryPermissionAndFormatOneReadsAsVersionOne() throws {
    let files = #"{"main.janet": "sha256:\#(String(repeating: "a", count: 64))"}"#
    let one = try ControllerDescriptor.parse(
      Data(
        #"{"format": 1, "id": "dev.uniterm.fixture.two", "name": "X", "entry": {"kind": "janet", "path": "main.janet"}, "files": \#(files), "permissions": [{"kind": "pane-control"}, {"kind": "capability", "name": "fs-read"}]}"#
          .utf8))
    let two = try ControllerDescriptor.parse(
      Data(
        #"{"format": 2, "id": "dev.uniterm.fixture.two", "name": "X", "entry": {"kind": "janet", "path": "main.janet"}, "files": \#(files), "permissions": [{"kind": "pane-control", "version": 1}, {"kind": "capability", "name": "fs-read", "version": 1}, {"kind": "clipboard-read", "version": 1}, {"kind": "clipboard-write", "version": 1}, {"kind": "host-launch", "version": 1, "executable": "/usr/bin/true", "directory": "/tmp", "environment": ["TOKEN", "A_KEY"]}]}"#
          .utf8))

    XCTAssertEqual(one.permissions, [.paneControl, .capability("fs-read")])
    XCTAssertTrue(one.permissions.allSatisfy { $0.version == 1 })
    XCTAssertEqual(
      two.permissions,
      [
        .paneControl, .capability("fs-read"), .clipboardRead, .clipboardWrite,
        .hostLaunch(
          try HostLaunchScope(
            executable: "/usr/bin/true", directory: "/tmp", environmentKeys: ["A_KEY", "TOKEN"])),
      ])
  }
}
