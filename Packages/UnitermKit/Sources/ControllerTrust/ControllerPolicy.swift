import ControllerPackage
import Foundation

/// What a remembered approval names: one exact verified version of a controller, or a signing
/// key together with a controller ID, across every version that key signs.
public enum ControllerSelector: Hashable, Sendable {
  /// The descriptor's SHA-256 as lowercase hex. It covers the packaged code too.
  case version(controllerID: String, version: String)

  /// The SHA-256 of the signing public key as lowercase hex.
  case identity(controllerID: String, keyFingerprint: String)

  public var controllerID: String {
    switch self {
    case .version(let id, _), .identity(let id, _): return id
    }
  }

  /// True when a verified run of `identity` is one this selector names. A selector never matches
  /// on a name, a path, or a digest a peer claims: the identity comes from the app's own reading
  /// of the snapshot.
  public func matches(_ identity: ControllerIdentity) -> Bool {
    switch self {
    case .version(let id, let version):
      return identity.controllerID == id && identity.version == version

    case .identity(let id, let fingerprint):
      return identity.controllerID == id && identity.keyFingerprint == fingerprint
    }
  }

  /// The selector's kind as the policy file spells it.
  public var kindName: String {
    switch self {
    case .version: return "version"
    case .identity: return "identity"
    }
  }

  /// The version digest or the key fingerprint.
  public var value: String {
    switch self {
    case .version(_, let version): return version
    case .identity(_, let fingerprint): return fingerprint
    }
  }
}

/// One remembered approval: a selector, and the typed permissions approved for runs it names.
///
/// It holds no connection, process, pane, or window, so it can never restore a live binding. A run
/// it covers still needs its own admission, and gets its pane scope from that run alone.
public struct ControllerPolicy: Hashable, Sendable {
  public let selector: ControllerSelector

  /// The display name the controller gave when the user approved it. It proves nothing.
  public let name: String

  /// The approved ceiling. Arguments and environment values are never part of it.
  public let scopes: Set<ControllerPermission>

  /// When the user approved it, as ISO 8601 text.
  public let approved: String

  public init(
    selector: ControllerSelector, name: String, scopes: Set<ControllerPermission>,
    approved: String
  ) {
    self.selector = selector
    self.name = name
    self.scopes = scopes
    self.approved = approved
  }

  /// The permissions of `requested` this policy does not cover. Empty means covered.
  public func uncovered(_ requested: Set<ControllerPermission>) -> [ControllerPermission] {
    PermissionContainment.uncovered(requested, by: scopes)
  }
}

/// The semantic comparison of a request with an approval. A request is covered when each of its
/// permissions is the same as, or narrower than, one approved permission. A broader scope, another
/// power, or a meaning this version does not know is never covered.
public enum PermissionContainment {
  public static func uncovered(
    _ requested: Set<ControllerPermission>, by approved: Set<ControllerPermission>
  ) -> [ControllerPermission] {
    requested.filter { wanted in !approved.contains { wanted.isCovered(by: $0) } }.sorted()
  }

  /// The union of an existing approval and a newly approved request, with nothing the new request
  /// already covers listed twice.
  public static func merged(
    _ existing: Set<ControllerPermission>, with added: Set<ControllerPermission>
  ) -> Set<ControllerPermission> {
    var result = existing

    for permission in added where !result.contains(where: { permission.isCovered(by: $0) }) {
      result.insert(permission)
    }

    return result
  }
}

extension ControllerPermission {
  /// True when this permission asks for no more than `approved` allows.
  ///
  /// The kinds must match, and the approved version's meaning must cover this version, so a higher
  /// version, or one this build does not know, is never covered. A host launch is narrower when it
  /// names the same executable, a directory inside the approved one, and no environment key
  /// beyond the approved keys. Every other scope must be the same.
  public func isCovered(by approved: ControllerPermission) -> Bool {
    guard meaning != nil, let allowed = approved.meaning, kind.name == approved.kind.name,
      allowed.covers.contains(version)
    else { return false }

    switch (kind, approved.kind) {
    case (.hostLaunch(let wanted), .hostLaunch(let scope)):
      return wanted.executable == scope.executable
        && scope.allows(directory: wanted.directory)
        && Set(wanted.environmentKeys).isSubset(of: Set(scope.environmentKeys))

    default:
      return kind == approved.kind
    }
  }

  /// How a review and the Controllers & Permissions window name the permission.
  public var displayText: String {
    let text: String

    switch kind {
    case .paneControl:
      text = "Control panes it may address"

    case .capability(let name):
      text = "Janet capability \(name)"

    case .clipboardRead:
      text = "Read the clipboard"

    case .clipboardWrite:
      text = "Replace the clipboard"

    case .hostLaunch(let scope):
      let keys =
        scope.environmentKeys.isEmpty ? "none" : scope.environmentKeys.joined(separator: ", ")

      text =
        "Start \(scope.executable) as a driver, with any arguments, in \(scope.directory) or a "
        + "folder inside it, with environment keys \(keys) and any values"
    }

    return version == 1 ? text : "\(text) (version \(version))"
  }
}
