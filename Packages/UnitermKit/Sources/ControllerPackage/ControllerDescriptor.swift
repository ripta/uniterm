import CryptoKit
import Foundation
import ScriptWire

/// Why a controller package, its descriptor, its signature, or its snapshot was refused. Each case
/// carries text for the user, which names the file or field at fault.
public enum ControllerPackageError: Error, Equatable, CustomStringConvertible, Sendable {
  /// The descriptor or signature is not the strict format this version reads.
  case malformed(String)

  /// The package on disk does not match what its descriptor lists.
  case contents(String)

  /// The signature file is present and does not verify.
  case signature(String)

  /// A native entry or library loads code from outside the package and the system.
  case loadBoundary(String)

  /// The file system refused a read or a write.
  case io(String)

  public var description: String {
    switch self {
    case .malformed(let text): return "controller.json: \(text)"
    case .contents(let text): return text
    case .signature(let text): return "controller.sig: \(text)"
    case .loadBoundary(let text): return text
    case .io(let text): return text
    }
  }
}

/// What a controller runs: a Janet script run by uniterm's own helper, or a native executable.
public enum ControllerEntryKind: String, Sendable, Equatable {
  case janet
  case native
}

/// A power a controller declares. Every kind has one meaning in this descriptor format. A kind this
/// version does not know is refused, so a newer meaning never authorizes anything here.
public enum ControllerPermission: Hashable, Sendable, Comparable {
  /// The controller acts on the panes its run may address, within the pane rules.
  case paneControl

  /// A Janet sandbox capability, by the name `uniterm run --allow` takes. Only a Janet entry may
  /// declare one.
  case capability(String)

  public static func < (lhs: ControllerPermission, rhs: ControllerPermission) -> Bool {
    lhs.sortKey < rhs.sortKey
  }

  private var sortKey: String {
    switch self {
    case .paneControl: return "0"
    case .capability(let name): return "1" + name
    }
  }
}

/// A controller's `controller.json`, read strictly from its exact bytes.
///
/// The app, the signer, and the helper's loader all read a descriptor through `parse`, so they
/// cannot disagree about what a file means. The version digest is SHA-256 over those bytes. The
/// descriptor lists the digest of every packaged file, so the version digest covers the code too.
public struct ControllerDescriptor: Equatable, Sendable {
  /// The descriptor format this version reads and writes. A file of another format is refused.
  public static let format = 1

  /// The descriptor's name inside a package.
  public static let fileName = "controller.json"

  public static let maxBytes = 64 * 1024
  public static let maxFiles = 512
  public static let maxFileBytes = 32 * 1024 * 1024
  public static let maxPackageBytes = 128 * 1024 * 1024
  public static let maxIDBytes = 128
  public static let maxNameBytes = 64
  public static let maxPathBytes = 1024
  public static let maxPathDepth = 16
  public static let maxComponentBytes = 255

  /// Capabilities a controller may not declare, since each one loads native code that the
  /// package does not hold and the app cannot check.
  public static let refusedCapabilities: Set<String> = [
    "ffi", "ffi-define", "ffi-jit", "ffi-use", "modules",
  ]

  /// The stable controller ID, such as `dev.example.slides`.
  public let id: String

  /// The name shown to the user. It proves nothing about who wrote the controller.
  public let name: String

  public let entryKind: ControllerEntryKind

  /// The entry's path inside the package.
  public let entryPath: String

  /// Each packaged file's path and SHA-256 digest, sorted by path.
  public let files: [String: Data]

  public let permissions: Set<ControllerPermission>

  /// SHA-256 over the descriptor's exact bytes.
  public let versionDigest: Data

  /// Reads a descriptor. Every rule is checked before it returns, and the first broken one throws.
  public static func parse(_ bytes: Data) throws -> ControllerDescriptor {
    let document: StrictJSON

    do {
      document = try StrictJSONReader.parse(bytes, maxBytes: maxBytes)
    } catch let error as StrictJSONError {
      throw ControllerPackageError.malformed(error.description)
    }

    let fields = try document.members(
      of: "the descriptor", required: ["format", "id", "name", "entry", "files", "permissions"])

    let format = try fields["format"]!.integer("format")

    guard format == Self.format else {
      throw ControllerPackageError.malformed(
        "format \(format) is not one this uniterm reads. It reads format \(Self.format).")
    }

    let id = try fields["id"]!.string("id")

    try checkID(id)

    let name = try fields["name"]!.string("name")

    try checkName(name)

    let entry = try fields["entry"]!.members(of: "entry", required: ["kind", "path"])
    let kindText = try entry["kind"]!.string("entry kind")

    guard let kind = ControllerEntryKind(rawValue: kindText) else {
      throw ControllerPackageError.malformed(
        "entry kind \"\(kindText)\" is not janet or native")
    }

    let entryPath = try entry["path"]!.string("entry path")

    try checkPath(entryPath)

    let files = try readFiles(fields["files"]!)

    guard files[entryPath] != nil else {
      throw ControllerPackageError.malformed("the entry \(entryPath) is not among the files")
    }

    if kind == .janet {
      guard entryPath.hasSuffix(".janet") else {
        throw ControllerPackageError.malformed("a Janet entry must be a .janet file")
      }
    }

    let permissions = try readPermissions(fields["permissions"]!, kind: kind)

    return ControllerDescriptor(
      id: id, name: name, entryKind: kind, entryPath: entryPath, files: files,
      permissions: permissions, versionDigest: Data(SHA256.hash(data: bytes)))
  }

  /// The Janet capabilities the descriptor declares.
  public var capabilities: Set<String> {
    Set(
      permissions.compactMap {
        if case .capability(let name) = $0 { return name }

        return nil
      })
  }

  /// The version digest as lowercase hex.
  public var versionHex: String { versionDigest.hex }

  private static func checkID(_ id: String) throws {
    let bytes = Array(id.utf8)
    let allowed = { (byte: UInt8) in
      (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
        || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
        || byte == UInt8(ascii: "-")
    }
    let labels = id.split(separator: ".", omittingEmptySubsequences: false)

    guard !bytes.isEmpty, bytes.count <= maxIDBytes, labels.count >= 2,
      labels.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy(allowed) })
    else {
      throw ControllerPackageError.malformed(
        "id must be a reverse domain name of lowercase letters, digits, and hyphens, such as "
          + "dev.example.slides, at most \(maxIDBytes) bytes")
    }
  }

  private static func checkName(_ name: String) throws {
    let printable = name.unicodeScalars.allSatisfy { scalar in
      !scalar.properties.generalCategory.isControlOrFormat
    }

    guard !name.isEmpty, name.utf8.count <= maxNameBytes, printable,
      name.trimmingCharacters(in: .whitespaces) == name
    else {
      throw ControllerPackageError.malformed(
        "name must be 1 to \(maxNameBytes) bytes of printable text with no edge spaces")
    }
  }

  /// A packaged path is relative and plain: components of ASCII letters, digits, `.`, `_`, and
  /// `-`, each starting with a letter or a digit. Nothing can climb out, name the descriptor, or
  /// spell one file two ways under Unicode normalization.
  static func checkPath(_ path: String) throws {
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    let plain = components.allSatisfy { component in
      guard let first = component.utf8.first, component.utf8.count <= maxComponentBytes else {
        return false
      }

      let isAlphanumeric = { (byte: UInt8) in
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
          || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
          || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
      }

      return isAlphanumeric(first)
        && component.utf8.allSatisfy {
          isAlphanumeric($0) || $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "_")
            || $0 == UInt8(ascii: "-")
        }
    }

    guard plain, path.utf8.count <= maxPathBytes, components.count <= maxPathDepth else {
      throw ControllerPackageError.malformed(
        "the path \"\(path.debugDescription.dropFirst().dropLast())\" is not a plain relative path. "
          + "Use components of letters, digits, '.', '_', and '-' that start with a letter or a "
          + "digit, joined by '/'.")
    }

    let reserved = [fileName, ControllerSignature.fileName].map { $0.lowercased() }

    guard !reserved.contains(path.lowercased()) else {
      throw ControllerPackageError.malformed("\(path) is reserved and cannot be a packaged file")
    }
  }

  private static func readFiles(_ value: StrictJSON) throws -> [String: Data] {
    let members = try value.object("files")

    guard !members.isEmpty, members.count <= maxFiles else {
      throw ControllerPackageError.malformed("files must list 1 to \(maxFiles) files")
    }

    var files: [String: Data] = [:]

    // The default macOS file system ignores case, so two paths that differ only by case would be
    // one file there.
    var folded: [String: String] = [:]

    for member in members {
      try checkPath(member.key)

      let key = member.key.lowercased()

      if let earlier = folded[key] {
        throw ControllerPackageError.malformed(
          "\(earlier) and \(member.key) name the same file on a case-insensitive disk")
      }

      folded[key] = member.key
      files[member.key] = try readDigest(member.value, for: member.key)
    }

    for path in files.keys {
      var prefix = ""

      for component in path.split(separator: "/").dropLast() {
        prefix += prefix.isEmpty ? String(component) : "/" + component

        if let file = folded[prefix.lowercased()] {
          throw ControllerPackageError.malformed(
            "\(file) is a file, so \(path) cannot be inside it")
        }
      }
    }

    return files
  }

  private static func readDigest(_ value: StrictJSON, for path: String) throws -> Data {
    let text = try value.string("the digest of \(path)")
    let prefix = "sha256:"
    let hex = text.dropFirst(prefix.count)

    guard text.hasPrefix(prefix), hex.count == 64,
      hex.utf8.allSatisfy({
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
          || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
      }),
      let digest = Data(hex: String(hex))
    else {
      throw ControllerPackageError.malformed(
        "the digest of \(path) must be sha256: and 64 lowercase hex digits")
    }

    return digest
  }

  private static func readPermissions(
    _ value: StrictJSON, kind: ControllerEntryKind
  ) throws -> Set<ControllerPermission> {
    var permissions = Set<ControllerPermission>()

    for element in try value.array("permissions") {
      let fields = try element.members(
        of: "a permission", required: ["kind"], optional: ["name"])
      let permissionKind = try fields["kind"]!.string("a permission's kind")
      let permission: ControllerPermission

      switch permissionKind {
      case "pane-control":
        guard fields["name"] == nil else {
          throw ControllerPackageError.malformed("pane-control takes no name")
        }

        permission = .paneControl

      case "capability":
        guard kind == .janet else {
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

        guard !refusedCapabilities.contains(name) else {
          throw ControllerPackageError.malformed(
            "a controller cannot declare \(name), since it loads native code from outside the "
              + "package")
        }

        permission = .capability(name)

      default:
        throw ControllerPackageError.malformed(
          "the permission kind \"\(permissionKind)\" is not one this uniterm knows")
      }

      guard permissions.insert(permission).inserted else {
        throw ControllerPackageError.malformed("a permission is listed twice")
      }
    }

    return permissions
  }
}

extension Unicode.GeneralCategory {
  var isControlOrFormat: Bool {
    switch self {
    case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .privateUse,
      .unassigned:
      return true
    default:
      return false
    }
  }
}

extension Data {
  /// Lowercase hex.
  public var hex: String { map { String(format: "%02x", $0) }.joined() }

  /// Nil unless `hex` is an even number of hex digits.
  public init?(hex: String) {
    let digits = Array(hex.utf8)

    guard digits.count % 2 == 0 else { return nil }

    var bytes: [UInt8] = []

    for index in stride(from: 0, to: digits.count, by: 2) {
      guard let byte = UInt8(String(decoding: digits[index..<index + 2], as: UTF8.self), radix: 16)
      else { return nil }

      bytes.append(byte)
    }

    self.init(bytes)
  }
}
