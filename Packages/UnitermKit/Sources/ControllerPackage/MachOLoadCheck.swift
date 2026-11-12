import Foundation

/// Checks where a native controller's code can come from, before it runs.
///
/// dyld loads what an executable's load commands name. Every library a packaged Mach-O names must
/// be a system library or a packaged file, and every packaged library it names is checked the same
/// way. A search path outside the package and the system, an embedded dyld environment, or another
/// dynamic linker would let code the descriptor does not cover load first, so each is refused. An
/// entry whose boundary cannot be read is refused too, and is never run with a weaker guarantee.
///
/// It reads the load commands only. Code that calls dlopen at run time can still load anything
/// its own privileges allow, and no check of the file can stop that.
public enum MachOLoadCheck {
  /// The folders whose libraries count as the system's. They are on the read-only system volume.
  static let systemPrefixes = ["/usr/lib/", "/System/Library/"]

  static let maxCommands = 4096

  /// The deepest chain of packaged libraries followed.
  static let maxDepth = 32

  /// Throws unless the entry and every packaged library it reaches load only packaged files and
  /// system libraries. `files` holds every packaged file's bytes by its packaged path.
  public static func check(entry: String, files: [String: Data]) throws {
    guard let bytes = files[entry] else {
      throw ControllerPackageError.loadBoundary("the native entry \(entry) is not packaged")
    }

    var checked = Set<String>()

    try check(
      image: entry, bytes: bytes, executableFolder: folder(of: entry), inheritedRpaths: [],
      files: files, checked: &checked, depth: 0)
  }

  private static func check(
    image: String, bytes: Data, executableFolder: String, inheritedRpaths: [String],
    files: [String: Data], checked: inout Set<String>, depth: Int
  ) throws {
    guard depth <= maxDepth else {
      throw ControllerPackageError.loadBoundary("\(image) loads libraries too deeply nested")
    }

    let commands = try loadCommands(of: bytes, image: image)
    var rpaths = inheritedRpaths

    for rpath in commands.rpaths {
      guard let resolved = resolve(rpath, image: image, executableFolder: executableFolder) else {
        throw ControllerPackageError.loadBoundary(
          "\(image) searches \(rpath) for libraries, which is outside the package and the system")
      }

      rpaths.append(resolved)
    }

    for library in commands.libraries {
      let candidates: [String]

      if library.hasPrefix("@rpath/") {
        let rest = String(library.dropFirst("@rpath/".count))

        candidates = rpaths.map { join($0, rest) }
      } else if let resolved = resolve(library, image: image, executableFolder: executableFolder) {
        candidates = [resolved]
      } else {
        throw ControllerPackageError.loadBoundary(
          "\(image) loads \(library), which is outside the package and the system")
      }

      let packagedCandidates = candidates.filter { !isSystem($0) && files[packaged($0)] != nil }

      guard candidates.contains(where: isSystem) || !packagedCandidates.isEmpty else {
        throw ControllerPackageError.loadBoundary(
          "\(image) loads \(library), which the package does not hold")
      }

      // dyld takes the first candidate that exists, and a system path may not exist on this Mac,
      // so every packaged candidate is one dyld could load and is checked.
      for candidate in packagedCandidates {
        let path = packaged(candidate)

        guard checked.insert(path).inserted, let library = files[path] else { continue }

        try check(
          image: path, bytes: library, executableFolder: executableFolder, inheritedRpaths: rpaths,
          files: files, checked: &checked, depth: depth + 1)
      }
    }
  }

  /// A packaged path is kept with a leading `@package/` while it is resolved, so it can never be
  /// mistaken for a path on disk.
  private static let packageRoot = "@package/"

  private static func packaged(_ path: String) -> String {
    String(path.dropFirst(packageRoot.count))
  }

  private static func isSystem(_ path: String) -> Bool {
    systemPrefixes.contains { path.hasPrefix($0) }
      && !path.split(separator: "/").contains { $0 == ".." || $0 == "." }
  }

  private static func folder(of path: String) -> String {
    let parts = path.split(separator: "/").dropLast()

    return packageRoot + parts.joined(separator: "/")
  }

  /// Resolves a load path against the package. Nil for a path that is neither the system's nor
  /// inside the package.
  private static func resolve(_ path: String, image: String, executableFolder: String) -> String? {
    if path.hasPrefix("/") { return isSystem(path) ? path : nil }

    let base: String
    let rest: String

    if path.hasPrefix("@executable_path/") {
      base = executableFolder
      rest = String(path.dropFirst("@executable_path/".count))
    } else if path == "@executable_path" {
      return executableFolder
    } else if path.hasPrefix("@loader_path/") {
      base = folder(of: image)
      rest = String(path.dropFirst("@loader_path/".count))
    } else if path == "@loader_path" {
      return folder(of: image)
    } else {
      return nil
    }

    return normalized(join(base, rest))
  }

  private static func join(_ base: String, _ rest: String) -> String {
    base.hasSuffix("/") ? base + rest : base + "/" + rest
  }

  /// Folds `.` and `..` inside the package. Nil when the path climbs out of it.
  private static func normalized(_ path: String) -> String? {
    if !path.hasPrefix(packageRoot) {
      return isSystem(path) ? path : nil
    }

    var parts: [Substring] = []

    for part in path.dropFirst(packageRoot.count).split(separator: "/") {
      switch part {
      case ".": continue
      case "..":
        guard !parts.isEmpty else { return nil }

        parts.removeLast()
      default: parts.append(part)
      }
    }

    return packageRoot + parts.joined(separator: "/")
  }

  struct Commands {
    var libraries: [String] = []
    var rpaths: [String] = []
  }

  private static let fatMagic: UInt32 = 0xcafe_babe
  private static let fatMagic64: UInt32 = 0xcafe_babf
  private static let magic64: UInt32 = 0xfeed_facf

  /// The libraries and search paths of every slice. A fat file's slices are each read, since dyld
  /// may pick any of them.
  static func loadCommands(of bytes: Data, image: String) throws -> Commands {
    guard bytes.count >= 8 else { throw notMachO(image) }

    let magic = bytes.readBigEndian(at: 0)

    guard magic == fatMagic || magic == fatMagic64 else {
      return try thinCommands(bytes, image: image)
    }

    let count = Int(bytes.readBigEndian(at: 4))
    let entrySize = magic == fatMagic ? 20 : 32

    guard count > 0, count <= 16, 8 + count * entrySize <= bytes.count else {
      throw notMachO(image)
    }

    var all = Commands()

    for index in 0..<count {
      let entry = 8 + index * entrySize
      let offset: Int
      let size: Int

      if magic == fatMagic {
        offset = Int(bytes.readBigEndian(at: entry + 8))
        size = Int(bytes.readBigEndian(at: entry + 12))
      } else {
        offset = Int(bytes.readBigEndian64(at: entry + 8))
        size = Int(bytes.readBigEndian64(at: entry + 16))
      }

      guard offset >= 0, size > 0, offset <= bytes.count, size <= bytes.count - offset else {
        throw notMachO(image)
      }

      let slice = try thinCommands(bytes.subdata(in: offset..<offset + size), image: image)

      all.libraries += slice.libraries
      all.rpaths += slice.rpaths
    }

    return all
  }

  private static func thinCommands(_ bytes: Data, image: String) throws -> Commands {
    let headerSize = 32

    guard bytes.count >= headerSize, bytes.readLittleEndian(at: 0) == magic64 else {
      throw ControllerPackageError.loadBoundary(
        "\(image) is not a 64-bit Mach-O file, so what it loads cannot be checked")
    }

    let count = Int(bytes.readLittleEndian(at: 16))
    let size = Int(bytes.readLittleEndian(at: 20))

    guard count <= maxCommands, size <= bytes.count - headerSize else { throw notMachO(image) }

    var commands = Commands()
    var offset = headerSize
    let end = headerSize + size

    for _ in 0..<count {
      guard offset + 8 <= end else { throw notMachO(image) }

      let command = bytes.readLittleEndian(at: offset)
      let commandSize = Int(bytes.readLittleEndian(at: offset + 4))

      guard commandSize >= 8, commandSize <= end - offset else { throw notMachO(image) }

      let body = bytes.subdata(in: offset..<offset + commandSize)

      switch command {
      case 0xc, 0x8000_0018, 0x8000_001f, 0x20, 0x8000_0023:
        commands.libraries.append(try string(in: body, image: image))

      case 0x8000_001c:
        commands.rpaths.append(try string(in: body, image: image))

      case 0xe:
        let linker = try string(in: body, image: image)

        guard linker == "/usr/lib/dyld" else {
          throw ControllerPackageError.loadBoundary(
            "\(image) names the dynamic linker \(linker), not the system's")
        }

      case 0x27:
        throw ControllerPackageError.loadBoundary(
          "\(image) sets dyld environment variables of its own")

      default:
        break
      }

      offset += commandSize
    }

    return commands
  }

  /// The string a load command points at with the offset in its third word.
  private static func string(in body: Data, image: String) throws -> String {
    guard body.count >= 12 else { throw notMachO(image) }

    let offset = Int(body.readLittleEndian(at: 8))

    guard offset >= 12, offset < body.count else { throw notMachO(image) }

    let bytes = body[body.startIndex + offset..<body.endIndex].prefix { $0 != 0 }

    guard let text = String(validating: bytes, as: UTF8.self), !text.isEmpty else {
      throw notMachO(image)
    }

    return text
  }

  private static func notMachO(_ image: String) -> ControllerPackageError {
    .loadBoundary(
      "\(image) is not a Mach-O file uniterm can read, so what it loads cannot be checked")
  }
}

extension Data {
  fileprivate func readLittleEndian(at offset: Int) -> UInt32 {
    guard offset >= 0, offset + 4 <= count else { return 0 }

    return withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
      .littleEndian
  }

  fileprivate func readBigEndian(at offset: Int) -> UInt32 {
    guard offset >= 0, offset + 4 <= count else { return 0 }

    return UInt32(
      bigEndian: withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) })
  }

  fileprivate func readBigEndian64(at offset: Int) -> UInt64 {
    guard offset >= 0, offset + 8 <= count else { return 0 }

    return UInt64(
      bigEndian: withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self) })
  }
}
