import Darwin
import FileRouting
import Foundation
import XCTest

final class SenderIdentityTests: XCTestCase {
  /// An `audit_token_t` whose process ID and version are the two words the code reads.
  private func token(pid: UInt32, version: UInt32) -> Data {
    var words = [UInt32](repeating: 0, count: 8)
    words[5] = pid
    words[7] = version

    return words.withUnsafeBytes { Data($0) }
  }

  private func ownToken() throws -> AuditToken {
    var raw = audit_token_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<audit_token_t>.size / MemoryLayout<natural_t>.size)

    let status = withUnsafeMutablePointer(to: &raw) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_AUDIT_TOKEN), $0, &count)
      }
    }

    XCTAssertEqual(status, KERN_SUCCESS)

    let data = withUnsafeBytes(of: &raw) { Data($0) }
    return try XCTUnwrap(AuditToken(data: data))
  }

  // MARK: Audit token

  /// Catches a token read at the wrong offset. The expected words come from a hand-built token and
  /// from this process's own token, which the kernel fills.
  func testTheTokenYieldsItsProcessIDAndVersion() throws {
    let built = try XCTUnwrap(AuditToken(data: token(pid: 4242, version: 77)))

    XCTAssertEqual(built.pid, 4242)
    XCTAssertEqual(built.pidVersion, 77)

    let own = try ownToken()
    XCTAssertEqual(own.pid, getpid())
  }

  func testATokenOfTheWrongSizeIsRejected() {
    XCTAssertNil(AuditToken(data: Data(count: 31)))
    XCTAssertNil(AuditToken(data: Data(count: 33)))
  }

  // MARK: Identity

  /// Catches a session that would treat a reused process ID as the same sender. The kernel bumps
  /// the version when it reuses an ID, so the two must differ.
  func testAReusedProcessIDWithADifferentVersionIsADifferentIdentity() {
    func identity(version: Int32) -> SenderIdentity {
      SenderIdentity(
        pid: 500, pidVersion: version, signingIdentifier: "com.example.app", teamIdentifier: nil,
        isPlatformBinary: false, isAppleAnchored: false, opener: nil)
    }

    XCTAssertEqual(identity(version: 1), identity(version: 1))
    XCTAssertNotEqual(identity(version: 1), identity(version: 2))
    XCTAssertEqual(Set([identity(version: 1), identity(version: 2)]).count, 2)
  }

  /// Catches the lookup that binds to a process ID alone. This process resolves with its own
  /// token. The same ID with another version does not resolve, which is how a reused ID and an
  /// exited sender both end up unidentified.
  func testTheLookupBindsToTheProcessIDVersion() throws {
    let own = try ownToken()
    let resolver = SystemSenderResolver()

    let identity = try XCTUnwrap(resolver.identity(of: own))
    XCTAssertEqual(identity.pid, own.pid)
    XCTAssertEqual(identity.pidVersion, own.pidVersion)
    XCTAssertNil(identity.opener, "a test runner is not an Apple opener")

    let reused = try XCTUnwrap(
      AuditToken(
        data: token(pid: UInt32(own.pid), version: UInt32(bitPattern: own.pidVersion &+ 1))
      ))
    XCTAssertNil(resolver.identity(of: reused))
  }

  /// A token naming no process cannot be identified.
  func testAnExitedSenderIsUnidentified() throws {
    let gone = try XCTUnwrap(AuditToken(data: token(pid: 2_000_000_000, version: 1)))

    XCTAssertNil(SystemSenderResolver().identity(of: gone))
    XCTAssertEqual(OpenAuthority.decide(for: nil), .refused(sender: "an unidentified program"))
  }

  // MARK: Apple openers

  private static let genericApple = ["/usr/bin/osascript", "/usr/bin/python3", "/usr/bin/open"]

  /// Catches a requirement set that a generic Apple binary satisfies. Any program can drive
  /// `osascript`, `python3`, and `/usr/bin/open`, so none may count as the user's act. The real
  /// signing identifiers are checked against the set, and Finder is the control that proves the
  /// check can match.
  func testGenericAppleBinariesNeverMatchAnAppleOpener() throws {
    let openerIdentifiers = AppleOpeners.all.map(\.requirement)

    for path in Self.genericApple {
      let url = URL(fileURLWithPath: path)
      let identifier = try XCTUnwrap(AppleOpeners.signingIdentifier(ofExecutableAt: url), path)

      XCTAssertNil(AppleOpeners.opener(forExecutableAt: url), path)
      XCTAssertFalse(
        openerIdentifiers.contains { $0.contains("\"\(identifier)\"") },
        "\(path) is signed as \(identifier), which an opener requirement names")
    }

    let finder = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
    XCTAssertEqual(AppleOpeners.opener(forExecutableAt: finder), "Finder")
  }

  /// Catches an opener whose identifier is not what the system's binary carries. The Dock and
  /// Spotlight are checked against the real programs.
  func testTheDockAndSpotlightMatchTheirOwnRequirements() {
    let dock = URL(fileURLWithPath: "/System/Library/CoreServices/Dock.app")
    let spotlight = URL(fileURLWithPath: "/System/Library/CoreServices/Spotlight.app")

    XCTAssertEqual(AppleOpeners.opener(forExecutableAt: dock), "Dock")
    XCTAssertEqual(AppleOpeners.opener(forExecutableAt: spotlight), "Spotlight")
  }

  /// Catches a requirement that trusts the identifier without the Apple anchor. A program of this
  /// package's tests claiming `com.apple.finder` is not Finder, so the requirement text must carry
  /// the anchor.
  func testEveryOpenerRequirementNamesTheAppleAnchor() {
    for opener in AppleOpeners.all {
      XCTAssertTrue(opener.requirement.hasPrefix("anchor apple and identifier "), opener.name)
    }
  }

  // MARK: Event

  /// Catches a reader that invents a sender. The system fills both tokens on an event it
  /// delivers, and they cannot be set on a hand-built one, so only absence is checked here. The
  /// live read is measured against real senders.
  func testAnEventWithoutTokensHasNoSender() {
    let event = NSAppleEventDescriptor.appleEvent(
      withEventClass: 0x6165_7674, eventID: 0x6F64_6F63,
      targetDescriptor: NSAppleEventDescriptor.null(), returnID: -1, transactionID: 0)

    let empty = OpenEventSender.Tokens(sender: nil, actual: nil)

    XCTAssertEqual(OpenEventSender.tokens(of: event), empty)
    XCTAssertEqual(OpenEventSender.tokens(of: nil), empty)
  }
}
