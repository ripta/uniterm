import ControllerPackage
import Darwin
import FileRouting
import Foundation
import PaneModel
import ProcessInspection
import Security

/// Where the app keeps controller snapshots, and how it knows the bundle's own command.
public struct ControllerSettings: Sendable {
  /// The private folder that holds one snapshot folder per run.
  public let runsRoot: URL

  public let helper: any ControllerHelperIdentity

  public init(runsRoot: URL, helper: any ControllerHelperIdentity) {
    self.runsRoot = runsRoot
    self.helper = helper
  }

  /// The settings for the running app, with the command inside its own bundle. Each instance keeps
  /// its runs in a folder of its own under `root`, named for its process and the time that process
  /// started, as sent content does. A launch removes the folders of instances that are gone, and
  /// never one that a running instance still runs a controller from. `process` is a parameter so
  /// a test stands in for another instance.
  public static func atLaunch(
    root: URL, process: ProcessIdentity = .current,
    helper: any ControllerHelperIdentity = BundleHelperIdentity.current()
  ) throws -> ControllerSettings {
    try ControllerSnapshot.prepareRunsRoot(root)

    let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []

    for name in names {
      guard let owner = ProcessIdentity(folderName: name), owner == process || !owner.isRunning
      else { continue }

      let folder = root.appendingPathComponent(name, isDirectory: true)

      ControllerSnapshot.removeStale(in: folder)
      try? FileManager.default.removeItem(at: folder)
    }

    return ControllerSettings(
      runsRoot: root.appendingPathComponent(process.folderName, isDirectory: true), helper: helper)
  }

  /// The runs folder under the user's caches, which the app alone writes.
  public static func defaultRunsRoot() throws -> URL {
    let caches = try FileManager.default.url(
      for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let folder = caches.appendingPathComponent("dev.uniterm.app", isDirectory: true)

    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

    return folder.appendingPathComponent("controller-runs", isDirectory: true)
  }
}

/// Decides whether a running peer is the bundle's own `uniterm` command. Only that command loads a
/// Janet controller, so only it may ask for a controller run. A peer that is any other program,
/// such as another Janet interpreter, gets no controller identity however it describes itself.
public protocol ControllerHelperIdentity: Sendable {
  /// Nil when the process that holds `token` runs the bundle's command. Otherwise why it does not.
  func refusal(forPeer token: AuditToken) -> String?
}

/// The bundle's command, matched by its code directory hash.
///
/// Builds are signed ad hoc, with no team, so no signing requirement names them. The hash of the
/// code the peer runs must equal the hash of the command in the bundle the app runs from. The
/// command must carry the hardened runtime too, and no entitlement that lets dyld honor its
/// variables. Otherwise dyld would load whatever `DYLD_INSERT_LIBRARIES` names before the command's
/// own code ran, and the hash would still match.
public struct BundleHelperIdentity: ControllerHelperIdentity {
  public let helperURL: URL

  public init(helperURL: URL) {
    self.helperURL = helperURL
  }

  /// The command inside the running app's bundle.
  public static func current() -> BundleHelperIdentity {
    BundleHelperIdentity(
      helperURL: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/uniterm"))
  }

  public func refusal(forPeer token: AuditToken) -> String? {
    guard let expected = CodeIdentity.ofFile(at: helperURL) else {
      return "uniterm cannot read the signature of its own command at \(helperURL.path)."
    }

    guard expected.hasHardenedRuntime, !expected.allowsLoaderVariables else {
      return
        "uniterm's own command was built so that dyld variables can load code into it, without "
        + "the hardened runtime or with get-task-allow, so it cannot be trusted to load a "
        + "controller. Rebuild uniterm."
    }

    guard let running = CodeIdentity.ofProcess(token: token) else {
      return "uniterm cannot read the signature of the program that asked to run a controller."
    }

    guard running.codeDirectoryHash == expected.codeDirectoryHash else {
      return
        "Only the uniterm command inside this uniterm app may run a controller package. Run it "
        + "with that command."
    }

    return nil
  }
}

/// What the system says about a piece of signed code.
struct CodeIdentity: Equatable {
  /// The hash of the code directory, which covers every page of the executable.
  let codeDirectoryHash: Data

  let signingFlags: UInt32

  /// The entitlements the signature carries.
  let entitlements: [String: Any]

  /// The executable's path, for a running process.
  let path: String?

  /// The code signature's runtime flag.
  var hasHardenedRuntime: Bool { signingFlags & 0x10000 != 0 }

  /// True when an entitlement makes dyld honor its variables despite the hardened runtime.
  /// get-task-allow does, which Xcode adds to a debug build unless told not to.
  var allowsLoaderVariables: Bool {
    ["com.apple.security.get-task-allow", "com.apple.security.cs.allow-dyld-environment-variables"]
      .contains { entitlements[$0] as? Bool == true }
  }

  static func == (lhs: CodeIdentity, rhs: CodeIdentity) -> Bool {
    lhs.codeDirectoryHash == rhs.codeDirectoryHash && lhs.signingFlags == rhs.signingFlags
      && lhs.path == rhs.path
  }

  static func ofFile(at url: URL) -> CodeIdentity? {
    var code: SecStaticCode?

    guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
      SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess
    else { return nil }

    return identity(of: code, path: url.path)
  }

  /// The code a running process runs. The lookup goes through the audit token, which carries the
  /// process ID version, so a process that exited, or one that has since started another
  /// executable, is not found. The running code must still be valid.
  ///
  /// With `dynamicOnly`, it asks only for the running code's dynamic signing information: whether
  /// the running pages are still valid, which code directory hash they carry, and which file they
  /// came from. It asks for no check of the file on disk, so its cost does not grow with the file.
  /// Whether Security reads the file to answer was not measured. The caller compares the hash with
  /// one it read from a file it trusts.
  static func ofProcess(token: AuditToken, dynamicOnly: Bool = false) -> CodeIdentity? {
    var guest: SecCode?
    let attributes = [kSecGuestAttributeAudit: token.bytes] as CFDictionary

    guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest) == errSecSuccess,
      let guest
    else { return nil }

    if dynamicOnly {
      var information: CFDictionary?
      let flags = SecCSFlags(rawValue: kSecCSDynamicInformation | kSecCSSigningInformation)

      // A running code object stands in for its static code in this call.
      let code = unsafeBitCast(guest, to: SecStaticCode.self)

      guard SecCodeCopySigningInformation(code, flags, &information) == errSecSuccess,
        let info = information as? [String: Any],
        let status = (info[kSecCodeInfoStatus as String] as? NSNumber)?.uint32Value,
        status & 0x1 != 0,
        let hash = info[kSecCodeInfoUnique as String] as? Data
      else { return nil }

      return CodeIdentity(
        codeDirectoryHash: hash,
        signingFlags: (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0,
        entitlements: [:], path: (info[kSecCodeInfoMainExecutable as String] as? URL)?.path)
    }

    guard SecCodeCheckValidity(guest, [], nil) == errSecSuccess else { return nil }

    var staticCode: SecStaticCode?

    guard SecCodeCopyStaticCode(guest, [], &staticCode) == errSecSuccess, let staticCode else {
      return nil
    }

    var url: CFURL?
    let path = SecCodeCopyPath(staticCode, [], &url) == errSecSuccess ? (url as URL?)?.path : nil

    return identity(of: staticCode, path: path)
  }

  private static func identity(of code: SecStaticCode, path: String?) -> CodeIdentity? {
    var information: CFDictionary?

    guard
      SecCodeCopySigningInformation(
        code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
      let info = information as? [String: Any],
      let hash = info[kSecCodeInfoUnique as String] as? Data
    else { return nil }

    let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
    let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]

    return CodeIdentity(
      codeDirectoryHash: hash, signingFlags: flags, entitlements: entitlements, path: path)
  }
}

/// One admitted controller run: what was verified, and the live process and connection it is bound
/// to. It is the run's authority, never a remembered trust. It ends when the run's process exits or
/// starts another executable, when the connection closes, or when the user revokes the controller.
public struct ControllerRun: Sendable, Equatable {
  public let identity: ControllerIdentity

  /// The descriptor's display name, which proves nothing.
  public let name: String

  public let entryKind: ControllerEntryKind
  public let entryPath: String

  /// What the run may do: the descriptor's pane control, and the capabilities the user granted
  /// with `--allow`, each one declared.
  public let scopes: Set<ControllerPermission>

  public let pid: pid_t

  /// The process ID version of the process the run is bound to. The kernel gives a process a new
  /// one when it starts another executable.
  public let generation: Int32

  /// The connection the run was admitted on.
  public let connection: UInt64

  /// The session root the run's process descends from when it was admitted, if any.
  public let sourceRoot: ProcessIdentity?

  /// The window and pane the run acted for when it was admitted, if any.
  public let window: UInt64?
  public let pane: NodeID?

  /// The run's private snapshot.
  public let snapshot: URL

  public var declaresPaneControl: Bool { scopes.contains(.paneControl) }
}
