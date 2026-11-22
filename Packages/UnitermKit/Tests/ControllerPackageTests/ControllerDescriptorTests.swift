import ControllerTestSupport
import CryptoKit
import Foundation
import SourceAccess
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
      #"{"a": "\ud800"}"#, #"{"a": "\u0000"}"#, #"{"a": 01}"#, #"{"a": -01}"#, #"{"a": 1.}"#,
      #"{"a": 1e}"#, #"{"a": -}"#, #"{"a": tru}"#, #"{"a": nul}"#, #"{"a": "x"} x"#,
      #"[[[[[[[[[1]]]]]]]]]"#, "{\"a\": \"\u{01}\"}",
    ]

    for text in refused {
      XCTAssertThrowsError(try StrictJSONReader.parse(Data(text.utf8), maxBytes: 1024), text)
    }

    XCTAssertEqual(
      try StrictJSONReader.parse(Data(#"{"a": "😀", "b": [1, 23]}"#.utf8), maxBytes: 64),
      .object([("a", .string("\u{1F600}")), ("b", .array([.integer(1), .integer(23)]))]))
  }

  /// Catches a widened reader that reads a boolean, null, negative, fraction, or exponent as the
  /// integer case, or an integer outside the controller domain as one. A reader that matches
  /// `integer` must never see them.
  func testStrictJSONGivesEachNewValueKindItsOwnCase() throws {
    func value(_ text: String) throws -> StrictJSON {
      try StrictJSONReader.parse(Data(text.utf8), maxBytes: 1024)
    }

    XCTAssertEqual(try value("true"), .boolean(true))
    XCTAssertEqual(try value("false"), .boolean(false))
    XCTAssertEqual(try value("null"), .null)
    XCTAssertEqual(try value("999999999"), .integer(999_999_999))
    XCTAssertEqual(try value("0"), .integer(0))

    for text in ["-1", "-0", "1.0", "0.5", "1e2", "1E+2", "2.5e-3", "1000000000"] {
      XCTAssertEqual(try value(text), .number(text), text)
    }
  }

  /// Catches a widened reader that lets a descriptor, a signature, or a format 1 policy file
  /// accept a value kind it refused before. Each holds the new kinds where an integer, a string,
  /// or an unknown field would sit.
  func testControllerFormatsStillRefuseTheNewValueKinds() {
    let hash = String(repeating: "a", count: 64)

    for extra in ["true", "null", "-1", "0.5", "1e2"] {
      let descriptors = [
        #"{"format": \#(extra), "id": "dev.uniterm.fixture.x", "name": "X", "entry": {"kind": "janet", "path": "main.janet"}, "files": {"main.janet": "sha256:\#(hash)"}, "permissions": []}"#,
        #"{"format": 1, "id": "dev.uniterm.fixture.x", "name": \#(extra), "entry": {"kind": "janet", "path": "main.janet"}, "files": {"main.janet": "sha256:\#(hash)"}, "permissions": []}"#,
        #"{"format": 1, "id": "dev.uniterm.fixture.x", "name": "X", "entry": {"kind": "janet", "path": "main.janet"}, "files": {"main.janet": "sha256:\#(hash)"}, "permissions": [], "flag": \#(extra)}"#,
        #"{"format": 1, "id": "dev.uniterm.fixture.x", "name": "X", "entry": {"kind": "janet", "path": "main.janet"}, "files": {"main.janet": \#(extra)}, "permissions": []}"#,
      ]

      for text in descriptors {
        XCTAssertThrowsError(try ControllerDescriptor.parse(Data(text.utf8)), text)
      }

      let signature =
        #"{"format": \#(extra), "algorithm": "ed25519", "public-key": "AA==", "signature": "AA=="}"#

      XCTAssertThrowsError(try ControllerSignature.parse(Data(signature.utf8)), signature)
    }
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

  /// Catches a path-read permission read without its scope, with a scope that is not plain, listed
  /// twice, or given fields of another kind. The scope is its own type, so a host launch's
  /// directory field is not accepted in its place.
  func testPathReadTakesAPlainListOfDirectoriesAndNothingElse() throws {
    let files = #"{"main.janet": "sha256:\#(String(repeating: "a", count: 64))"}"#

    func parse(_ permission: String) throws -> ControllerDescriptor {
      try ControllerDescriptor.parse(
        Data(
          #"{"format": 2, "id": "dev.uniterm.fixture.read", "name": "X", "entry": {"kind": "janet", "path": "main.janet"}, "files": \#(files), "permissions": [\#(permission)]}"#
            .utf8))
    }

    let good = try parse(
      #"{"kind": "path-read", "version": 1, "directories": ["/work/b", "/work/a"]}"#)

    XCTAssertEqual(
      good.permissions, [.pathRead(try ReadScope(directories: ["/work/a", "/work/b"]))])

    for (bad, expected) in [
      (#"{"kind": "path-read", "version": 1}"#, "needs a list of directories"),
      (#"{"kind": "path-read", "version": 1, "directories": []}"#, "1 to"),
      (#"{"kind": "path-read", "version": 1, "directories": ["rel"]}"#, "absolute paths"),
      (#"{"kind": "path-read", "version": 1, "directories": ["/a/../b"]}"#, "absolute paths"),
      (#"{"kind": "path-read", "version": 1, "directories": ["/a", "/a"]}"#, "twice"),
      (#"{"kind": "path-read", "version": 1, "directories": [3]}"#, "string"),
      (#"{"kind": "path-read", "version": 1, "directory": "/a"}"#, "only host-launch"),
      (#"{"kind": "path-read", "version": 2, "directories": ["/a"]}"#, "version 2"),
      (#"{"kind": "pane-control", "version": 1, "directories": ["/a"]}"#, "only path-read"),
      (
        #"{"kind": "path-read", "version": 1, "directories": ["/a"]}, {"kind": "path-read", "version": 1, "directories": ["/b"]}"#,
        "listed twice"
      ),
    ] {
      XCTAssertThrowsError(try parse(bad), bad) { error in
        XCTAssertTrue("\(error)".contains(expected), "\(error) does not say \(expected)")
      }
    }
  }

  /// Catches a path-read permission that a format 1 descriptor reads. Format 1 knows two kinds.
  func testFormatOneRefusesPathRead() {
    let files = #"{"main.janet": "sha256:\#(String(repeating: "a", count: 64))"}"#

    XCTAssertThrowsError(
      try ControllerDescriptor.parse(
        Data(
          #"{"format": 1, "id": "dev.uniterm.fixture.read", "name": "X", "entry": {"kind": "janet", "path": "main.janet"}, "files": \#(files), "permissions": [{"kind": "path-read"}]}"#
            .utf8)))
  }

  /// Catches the descriptor format being bumped for a kind that needs no bump, which would make
  /// every older build refuse descriptors that hold none of it. An older build refuses a kind it
  /// does not know at any format, and it knew exactly these kinds, so a descriptor holding
  /// path-read reads as an unknown kind there. This build's reader is the stand-in for that
  /// refusal: it must word a kind it lacks the way the older build words this one.
  func testPathReadJoinsFormatTwoWithoutANewFormat() throws {
    XCTAssertEqual(ControllerDescriptor.format, 2)

    let olderKinds: Set<String> = [
      "pane-control", "capability", "clipboard-read", "clipboard-write", "host-launch",
    ]
    let known = Set(ControllerPermission.meanings.map(\.kind))

    XCTAssertEqual(
      known.subtracting(olderKinds),
      ["path-read", "browser-navigation", "browser-read", "ask-user"])
    XCTAssertEqual(ControllerPermission.meaning(kind: "path-read", version: 1)?.format, 2)

    let files = #"{"main.janet": "sha256:\#(String(repeating: "a", count: 64))"}"#

    XCTAssertThrowsError(
      try ControllerDescriptor.parse(
        Data(
          #"{"format": 2, "id": "dev.uniterm.fixture.read", "name": "X", "entry": {"kind": "janet", "path": "main.janet"}, "files": \#(files), "permissions": [{"kind": "path-reading", "version": 1, "directories": ["/a"]}]}"#
            .utf8))
    ) { error in
      XCTAssertTrue(
        "\(error)".contains("is not one descriptor format 2 knows"), "\(error)")
    }
  }

  /// Catches a browser kind that joins format 2 as a format bump, or one a format 2 reader reads
  /// without its version. Both kinds take no field, so each is listed once, whole.
  func testBrowserKindsJoinFormatTwoAtVersionOne() throws {
    XCTAssertEqual(ControllerDescriptor.format, 2)

    for kind in ["browser-navigation", "browser-read"] {
      let meaning = try XCTUnwrap(ControllerPermission.meaning(kind: kind, version: 1))

      XCTAssertEqual(meaning.format, 2, kind)
      XCTAssertEqual(meaning.covers, [1], kind)
      XCTAssertNil(ControllerPermission.meaning(kind: kind, version: 2), kind)
    }

    let descriptor = try ControllerDescriptor.parse(
      try ControllerFixtures.descriptor(ControllerFixtures.formatTwoBrowser))

    XCTAssertEqual(descriptor.permissions, [.paneControl, .browserNavigation, .browserRead])
  }

  /// Catches the ask power joining format 2 as a format bump, and a scope or a name that it
  /// silently accepts. It has no scope field, so a field on it is a mistake the reader names. A
  /// format 1 descriptor never reads it, since an older build did not know the kind.
  func testAskUserJoinsFormatTwoAtVersionOneWithNoScope() throws {
    let meaning = try XCTUnwrap(ControllerPermission.meaning(kind: "ask-user", version: 1))

    XCTAssertEqual(meaning.format, 2)
    XCTAssertEqual(meaning.covers, [1])
    XCTAssertNil(ControllerPermission.meaning(kind: "ask-user", version: 2))
    XCTAssertEqual(ControllerPermission.askUser.kindName, "ask-user")

    let files = #"{"main.janet": "sha256:\#(String(repeating: "a", count: 64))"}"#

    func descriptor(format: Int, permission: String) -> Data {
      let version = format >= 2 ? #", "version": 1"# : ""

      return Data(
        #"{"format": \#(format), "id": "dev.uniterm.fixture.ask", "name": "X", "entry": {"kind": "janet", "path": "main.janet"}, "files": \#(files), "permissions": [{"kind": "ask-user"\#(version)\#(permission)}]}"#
          .utf8)
    }

    XCTAssertEqual(
      try ControllerDescriptor.parse(descriptor(format: 2, permission: "")).permissions,
      [.askUser])

    for extra in [#", "name": "x""#, #", "directories": ["/a"]"#, #", "executable": "/bin/ls""#] {
      XCTAssertThrowsError(
        try ControllerDescriptor.parse(descriptor(format: 2, permission: extra)), extra)
    }

    XCTAssertThrowsError(try ControllerDescriptor.parse(descriptor(format: 1, permission: "")))
  }

  /// Catches a format 1 descriptor and a format 2 descriptor sharing one reader state: each loads
  /// with its own kinds, and format 1 never reads a browser kind.
  func testFormatOneAndTwoDescriptorsBothLoadEachWithItsOwnKinds() throws {
    let one = try ControllerDescriptor.parse(
      try ControllerFixtures.descriptor("format-one-pane-control"))
    let two = try ControllerDescriptor.parse(
      try ControllerFixtures.descriptor(ControllerFixtures.formatTwoBrowser))

    XCTAssertEqual(one.permissions, [.paneControl])
    XCTAssertEqual(two.permissions, [.paneControl, .browserNavigation, .browserRead])
  }
}
