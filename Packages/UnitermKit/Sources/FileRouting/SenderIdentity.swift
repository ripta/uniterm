import Foundation
import Security

/// The audit token of the process that sent an Apple Event. Only the process ID and its version
/// are read from it. The whole token goes to the code-signing lookup, which refuses a token whose
/// process has exited.
public struct AuditToken: Sendable, Equatable, Hashable {
  public static let byteCount = 32

  /// The 32 bytes of an `audit_token_t`, as the Apple Event carries them.
  public let bytes: Data

  public let pid: Int32
  public let pidVersion: Int32

  /// Nil when `data` is not the size of an audit token.
  public init?(data: Data) {
    guard data.count == Self.byteCount else { return nil }

    bytes = data
    pid = Int32(bitPattern: Self.word(5, in: data))
    pidVersion = Int32(bitPattern: Self.word(7, in: data))
  }

  /// The audit token's `val` array holds the process ID at index 5 and its version at index 7.
  private static func word(_ index: Int, in data: Data) -> UInt32 {
    data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self) }
  }
}

/// What uniterm knows about the sender of an open, read from its verified code signature.
///
/// Two identities are equal only when the process ID and its version both match. The kernel bumps
/// the version when it reuses a process ID, so a reused ID is a different sender.
public struct SenderIdentity: Sendable, Equatable, Hashable {
  public let pid: Int32
  public let pidVersion: Int32

  /// The signing identifier the signature carries, such as `com.apple.finder`.
  public let signingIdentifier: String?

  public let teamIdentifier: String?

  /// True when the system's platform binary flag is set for the sender.
  public let isPlatformBinary: Bool

  /// True when the signature chains to Apple's own anchor.
  public let isAppleAnchored: Bool

  /// The name of the Apple opener whose requirement the sender satisfies, if any.
  public let opener: String?

  public init(
    pid: Int32, pidVersion: Int32, signingIdentifier: String?, teamIdentifier: String?,
    isPlatformBinary: Bool, isAppleAnchored: Bool, opener: String?
  ) {
    self.pid = pid
    self.pidVersion = pidVersion
    self.signingIdentifier = signingIdentifier
    self.teamIdentifier = teamIdentifier
    self.isPlatformBinary = isPlatformBinary
    self.isAppleAnchored = isAppleAnchored
    self.opener = opener
  }

  /// The longest sender name a message carries. A signing identifier is chosen by the sender.
  public static let longestName = 64

  /// A name for a message. It comes from the verified signing identifier, never from a path or a
  /// display name the sender controls.
  public var name: String {
    guard let signingIdentifier, !signingIdentifier.isEmpty else {
      return "an unsigned program (process \(pid))"
    }

    return Self.clean(signingIdentifier)
  }

  /// One line for the debug log, so a measurement can be repeated by hand.
  public var logDescription: String {
    "identifier=\(signingIdentifier ?? "none") team=\(teamIdentifier ?? "none") "
      + "platform=\(isPlatformBinary) apple=\(isAppleAnchored) pid=\(pid) "
      + "pidversion=\(pidVersion) opener=\(opener ?? "none")"
  }

  private static func clean(_ text: String) -> String {
    let printable = text.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }
    let cleaned = String(String.UnicodeScalarView(printable))

    guard cleaned.count > longestName else { return cleaned }

    return String(cleaned.prefix(longestName)) + "…"
  }
}

/// An Apple program whose open is the user's act, matched by a code-signing requirement.
public struct AppleOpener: Sendable, Equatable {
  public let name: String
  public let requirement: String

  public init(name: String, requirement: String) {
    self.name = name
    self.requirement = requirement
  }

  /// The requirement is a platform binary signed by Apple's own anchor, with an exact identifier.
  public init(name: String, identifier: String) {
    self.init(name: name, requirement: "anchor apple and identifier \"\(identifier)\"")
  }
}

/// The Apple openers that count as the user's act. Generic Apple binaries such as `osascript`,
/// `python3`, and `/usr/bin/open` are not on the list, since any program can drive them.
public enum AppleOpeners {
  /// Finder, the Dock, and Spotlight. Quick Look and Recent Items are not listed, since no signed
  /// program for either could be found on this system to name an identifier for.
  public static let all: [AppleOpener] = [
    AppleOpener(name: "Finder", identifier: "com.apple.finder"),
    AppleOpener(name: "Dock", identifier: "com.apple.dock"),
    AppleOpener(name: "Spotlight", identifier: "com.apple.Spotlight"),
  ]

  /// The opener whose requirement a running process satisfies.
  static func opener(for code: SecCode) -> String? {
    all.first { opener in
      guard let requirement = compile(opener.requirement) else { return false }

      return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }?.name
  }

  /// The opener whose requirement the program at `url` satisfies. Tests use it to show which real
  /// Apple binaries match, without a running sender.
  public static func opener(forExecutableAt url: URL) -> String? {
    var code: SecStaticCode?

    guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else {
      return nil
    }

    return all.first { opener in
      guard let requirement = compile(opener.requirement) else { return false }

      return SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
    }?.name
  }

  /// The signing identifier of the program at `url`.
  public static func signingIdentifier(ofExecutableAt url: URL) -> String? {
    var code: SecStaticCode?

    guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else {
      return nil
    }

    return signingInformation(of: code)?[kSecCodeInfoIdentifier as String] as? String
  }

  static func signingInformation(of code: SecStaticCode) -> [String: Any]? {
    var information: CFDictionary?

    let status = SecCodeCopySigningInformation(
      code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)

    guard status == errSecSuccess else { return nil }

    return information as? [String: Any]
  }

  private static func compile(_ text: String) -> SecRequirement? {
    var requirement: SecRequirement?

    guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess
    else { return nil }

    return requirement
  }
}

/// Reads a sender's identity from its audit token.
public protocol SenderResolving: Sendable {
  /// Nil when the sender cannot be identified, such as a sender that has already exited.
  func identity(of token: AuditToken) -> SenderIdentity?
}

/// Asks the system's code-signing services. The lookup binds to the audit token, which carries the
/// process ID version, so a sender that exited is unidentified, and a reused ID never matches.
public struct SystemSenderResolver: SenderResolving {
  public init() {}

  public func identity(of token: AuditToken) -> SenderIdentity? {
    var guest: SecCode?
    let attributes = [kSecGuestAttributeAudit: token.bytes] as CFDictionary

    guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest) == errSecSuccess,
      let guest, SecCodeCheckValidity(guest, [], nil) == errSecSuccess
    else { return nil }

    var staticCode: SecStaticCode?
    var information: [String: Any] = [:]

    if SecCodeCopyStaticCode(guest, [], &staticCode) == errSecSuccess, let staticCode {
      information = AppleOpeners.signingInformation(of: staticCode) ?? [:]
    }

    let platform = (information[kSecCodeInfoPlatformIdentifier as String] as? Int) ?? 0

    var anchor: SecRequirement?
    var apple = false

    if SecRequirementCreateWithString("anchor apple" as CFString, [], &anchor) == errSecSuccess,
      let anchor
    {
      apple = SecCodeCheckValidity(guest, [], anchor) == errSecSuccess
    }

    return SenderIdentity(
      pid: token.pid, pidVersion: token.pidVersion,
      signingIdentifier: information[kSecCodeInfoIdentifier as String] as? String,
      teamIdentifier: information[kSecCodeInfoTeamIdentifier as String] as? String,
      isPlatformBinary: platform != 0, isAppleAnchored: apple,
      opener: AppleOpeners.opener(for: guest))
  }
}
