import Foundation
import ScriptWire

/// The one reader of a permission list. A controller's `controller.json` and a script file's
/// declaration both hold one, so a package and a file cannot disagree about which kinds, versions,
/// fields, and scopes are allowed.
public enum ControllerPermissionReader {
  /// What declares the permissions. It only changes how a refusal is worded.
  public enum Subject: Sendable {
    case controller
    case file

    func unknownKind(_ kind: String, version: Int, format: Int) -> String {
      let known = ControllerPermission.meanings.contains { $0.kind == kind }

      switch self {
      case .controller:
        return format >= 2 && known
          ? "\(kind) version \(version) is not one this uniterm knows"
          : "the permission kind \"\(kind)\" is not one descriptor format \(format) knows"

      case .file:
        return known
          ? ":\(kind) version \(version) is not one this uniterm knows"
          : ":\(kind) is not a permission kind this uniterm knows"
      }
    }

    func refusedNativeCode(_ name: String) -> String {
      switch self {
      case .controller:
        return "a controller cannot declare \(name), since it loads native code from outside the "
          + "package"

      case .file:
        return "a script file cannot declare \(name), since it loads native code from outside the "
          + "snapshot an approval binds to"
      }
    }
  }

  /// Reads a `permissions` array. Every rule is checked, and the first broken one throws
  /// `ControllerPackageError.malformed`. A caller that is not a descriptor words the error for its
  /// own file.
  ///
  /// `allowsCapabilities` is false for a native entry, which declares no Janet capability.
  public static func read(
    _ value: StrictJSON, allowsCapabilities: Bool, format: Int, subject: Subject = .controller
  ) throws -> Set<ControllerPermission> {
    var permissions = Set<ControllerPermission>()
    var listed = Set<String>()

    for element in try value.array("permissions") {
      let fields = try element.members(
        of: "a permission", required: format >= 2 ? ["kind", "version"] : ["kind"],
        optional: ["name", "executable", "directory", "environment"])
      let permissionKind = try fields["kind"]!.string("a permission's kind")
      let version = try fields["version"]?.integer("a permission's version") ?? 1

      guard let meaning = ControllerPermission.meaning(kind: permissionKind, version: version),
        meaning.format <= format
      else {
        throw ControllerPackageError.malformed(
          subject.unknownKind(permissionKind, version: version, format: format))
      }

      let launchFields: Set<String> = ["executable", "directory", "environment"]

      guard permissionKind == "host-launch" || launchFields.isDisjoint(with: fields.keys) else {
        throw ControllerPackageError.malformed(
          "only host-launch takes an executable, a directory, or an environment")
      }

      if permissionKind != "capability", fields["name"] != nil {
        throw ControllerPackageError.malformed("\(permissionKind) takes no name")
      }

      let permissionValue: ControllerPermissionKind

      switch permissionKind {
      case "pane-control":
        permissionValue = .paneControl

      case "clipboard-read":
        permissionValue = .clipboardRead

      case "clipboard-write":
        permissionValue = .clipboardWrite

      case "host-launch":
        guard let executable = fields["executable"], let directory = fields["directory"],
          let environment = fields["environment"]
        else {
          throw ControllerPackageError.malformed(
            "host-launch needs an executable, a directory, and an environment list")
        }

        permissionValue = .hostLaunch(
          try HostLaunchScope(
            executable: try executable.string("a host launch's executable"),
            directory: try directory.string("a host launch's directory"),
            environmentKeys: try environment.array("a host launch's environment").map {
              try $0.string("an environment key")
            }))

      default:
        guard allowsCapabilities else {
          throw ControllerPackageError.malformed("only a Janet entry declares capabilities")
        }

        guard let nameValue = fields["name"] else {
          throw ControllerPackageError.malformed("a capability needs a name")
        }

        let name = try nameValue.string("a capability's name")

        guard ScriptCapabilityNames.grantable.contains(name) else {
          throw ControllerPackageError.malformed(
            "\(name) is not a capability uniterm run --allow can grant")
        }

        guard !ControllerDescriptor.refusedCapabilities.contains(name) else {
          throw ControllerPackageError.malformed(
            subject.refusedNativeCode(name))
        }

        permissionValue = .capability(name)
      }

      // A kind is listed once, or once for each capability name or host launch executable, at
      // whatever version. Two versions of one permission would leave its meaning unclear.
      guard listed.insert(permissionKind + "\u{0}" + permissionValue.scopeName).inserted else {
        throw ControllerPackageError.malformed("\(permissionKind) is listed twice")
      }

      permissions.insert(ControllerPermission(permissionValue, version: version))
    }

    return permissions
  }
}
