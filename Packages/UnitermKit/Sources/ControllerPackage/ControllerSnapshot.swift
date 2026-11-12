import CryptoKit
import Darwin
import Foundation

/// Who a verified controller is. Version trust names the version digest. Identity trust names the
/// key fingerprint and the controller ID together, and only a signed controller has a fingerprint.
public struct ControllerIdentity: Hashable, Sendable {
  public let controllerID: String

  /// SHA-256 over the descriptor's bytes, as lowercase hex.
  public let version: String

  /// SHA-256 over the signer's public key, as lowercase hex. Nil for an unsigned controller.
  public let keyFingerprint: String?

  public init(controllerID: String, version: String, keyFingerprint: String?) {
    self.controllerID = controllerID
    self.version = version
    self.keyFingerprint = keyFingerprint
  }
}

/// A descriptor that was read and, when signed, whose signature verified.
public struct VerifiedController: Equatable, Sendable {
  public let descriptor: ControllerDescriptor
  public let descriptorBytes: Data
  public let signature: ControllerSignature?

  /// A present signature file that does not verify throws, so it can never fall back to an
  /// unsigned controller with the same files.
  public init(descriptorBytes: Data, signatureBytes: Data?) throws {
    descriptor = try ControllerDescriptor.parse(descriptorBytes)
    self.descriptorBytes = descriptorBytes

    if let signatureBytes {
      let signature = try ControllerSignature.parse(signatureBytes)

      try signature.verify(descriptor: descriptorBytes)
      self.signature = signature
    } else {
      signature = nil
    }
  }

  public var identity: ControllerIdentity {
    ControllerIdentity(
      controllerID: descriptor.id, version: descriptor.versionHex,
      keyFingerprint: signature?.keyFingerprint)
  }
}

/// A private copy of a controller package, made for one run and verified once it is complete.
///
/// The copy is made from bytes read once through descriptors that never follow a link, and each
/// file's digest is checked on the bytes copied. The finished copy is then walked and read again:
/// it must hold exactly the listed files, each with its listed digest. Only then are its files and
/// folders made read-only. Changing the source package at any point, before, during, or after the
/// copy, cannot change what the run loads.
///
/// Read-only files that the user owns are no barrier to a process of the same user that means
/// harm. The snapshot keeps ordinary edits and updates out, and nothing more.
public struct ControllerSnapshot: Sendable {
  /// The run's private folder, which holds the copy at its top.
  public let directory: URL

  public let controller: VerifiedController

  /// The entry's path inside the snapshot.
  public var entryURL: URL { directory.appendingPathComponent(controller.descriptor.entryPath) }

  /// The most entries a package's folders may hold, files and folders together.
  static let maxEntries = 4096

  /// Copies the package at `source` into a new folder under `runsRoot` and verifies the copy.
  ///
  /// `afterCopying` runs after each listed file is copied, with its path. Only a test passes one,
  /// to change the source at a known point in the copy.
  public static func create(
    from source: String, in runsRoot: URL, afterCopying: ((String) -> Void)? = nil
  ) throws -> ControllerSnapshot {
    let sourceDirectory = try openDirectory(source, what: "the package \(source)")

    defer { close(sourceDirectory) }

    let descriptorBytes = try readFile(
      ControllerDescriptor.fileName, in: sourceDirectory, limit: ControllerDescriptor.maxBytes)
    let signatureBytes = try readOptionalFile(
      ControllerSignature.fileName, in: sourceDirectory, limit: ControllerSignature.maxBytes)
    let controller = try VerifiedController(
      descriptorBytes: descriptorBytes, signatureBytes: signatureBytes)
    let descriptor = controller.descriptor

    try checkTree(sourceDirectory, matches: descriptor, signed: signatureBytes != nil, what: source)

    let directory = try makeRunDirectory(in: runsRoot)
    let snapshot = ControllerSnapshot(directory: directory, controller: controller)

    do {
      let target = try openDirectory(directory.path, what: "the snapshot")

      defer { close(target) }

      try writeFile(ControllerDescriptor.fileName, bytes: descriptorBytes, in: target, mode: 0o400)

      if let signatureBytes {
        try writeFile(ControllerSignature.fileName, bytes: signatureBytes, in: target, mode: 0o400)
      }

      var total = 0
      var copied: [String: Data] = [:]

      for (path, digest) in descriptor.files.sorted(by: { $0.key < $1.key }) {
        let bytes = try readFile(
          path, in: sourceDirectory, limit: ControllerDescriptor.maxFileBytes)

        total += bytes.count

        guard total <= ControllerDescriptor.maxPackageBytes else {
          throw ControllerPackageError.contents(
            "the package holds more than \(ControllerDescriptor.maxPackageBytes) bytes")
        }

        guard Data(SHA256.hash(data: bytes)) == digest else {
          throw ControllerPackageError.contents(
            "\(path) does not match the digest controller.json lists for it")
        }

        let executable = descriptor.entryKind == .native && path == descriptor.entryPath

        try writeFile(path, bytes: bytes, in: target, mode: executable ? 0o500 : 0o400)
        copied[path] = bytes
        afterCopying?(path)
      }

      if descriptor.entryKind == .native {
        try MachOLoadCheck.check(entry: descriptor.entryPath, files: copied)
      }

      try verifyCopy(target, descriptorBytes: descriptorBytes, signatureBytes: signatureBytes)
      try lockFolders(target)
    } catch {
      snapshot.remove()

      throw error
    }

    return snapshot
  }

  /// Reads a snapshot back for loading, and checks it again. The descriptor's digest must be
  /// `version`, the one the app verified, and every listed file must match its digest. Returns the
  /// descriptor and each listed file's bytes, which are what the loader runs.
  public static func load(at path: String, version: Data) throws -> (
    descriptor: ControllerDescriptor, files: [String: Data]
  ) {
    let directory = try openDirectory(path, what: "the snapshot")

    defer { close(directory) }

    let descriptorBytes = try readFile(
      ControllerDescriptor.fileName, in: directory, limit: ControllerDescriptor.maxBytes)

    guard Data(SHA256.hash(data: descriptorBytes)) == version else {
      throw ControllerPackageError.contents(
        "the snapshot's controller.json is not the version uniterm verified")
    }

    let descriptor = try ControllerDescriptor.parse(descriptorBytes)
    var files: [String: Data] = [:]

    for (file, digest) in descriptor.files {
      let bytes = try readFile(file, in: directory, limit: ControllerDescriptor.maxFileBytes)

      guard Data(SHA256.hash(data: bytes)) == digest else {
        throw ControllerPackageError.contents("the snapshot's \(file) no longer matches its digest")
      }

      files[file] = bytes
    }

    return (descriptor, files)
  }

  /// Checks a package in place for signing: its descriptor reads, it holds exactly the listed
  /// files, and each matches its digest. A signature file it already holds is not checked, since
  /// signing replaces it. Returns the descriptor's exact bytes, which are what gets signed.
  public static func descriptorForSigning(at path: String) throws -> Data {
    let directory = try openDirectory(path, what: "the package \(path)")

    defer { close(directory) }

    let bytes = try readFile(
      ControllerDescriptor.fileName, in: directory, limit: ControllerDescriptor.maxBytes)
    let descriptor = try ControllerDescriptor.parse(bytes)
    let signed =
      try readOptionalFile(
        ControllerSignature.fileName, in: directory, limit: ControllerSignature.maxBytes) != nil

    try checkTree(directory, matches: descriptor, signed: signed, what: path)

    for (file, digest) in descriptor.files {
      let contents = try readFile(file, in: directory, limit: ControllerDescriptor.maxFileBytes)

      guard Data(SHA256.hash(data: contents)) == digest else {
        throw ControllerPackageError.contents(
          "\(file) does not match the digest controller.json lists for it")
      }
    }

    return bytes
  }

  /// Removes the snapshot. Safe to call twice.
  public func remove() {
    Self.removeTree(directory)
  }

  /// Removes the snapshot folder at `directory`. Safe to call twice.
  public static func remove(directory: URL) {
    removeTree(directory)
  }

  /// The folder runs live in, private to this user. Made when missing.
  public static func prepareRunsRoot(_ root: URL) throws {
    if mkdir(root.path, 0o700) != 0, errno != EEXIST {
      throw ControllerPackageError.io(
        "cannot make the controller runs folder \(root.path): \(errnoText())")
    }

    var info = stat()

    guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
      info.st_uid == geteuid()
    else {
      throw ControllerPackageError.io(
        "the controller runs folder \(root.path) is not a folder that belongs to you")
    }

    if info.st_mode & 0o077 != 0, chmod(root.path, 0o700) != 0 {
      throw ControllerPackageError.io("cannot make \(root.path) private: \(errnoText())")
    }
  }

  /// Removes every run folder under `root`. The app calls it once at launch, when no run is live,
  /// so the snapshots of runs that a crash cut short do not pile up.
  public static func removeStale(in root: URL) {
    let entries = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []

    for name in entries where name.hasPrefix(runPrefix) {
      removeTree(root.appendingPathComponent(name))
    }
  }

  static let runPrefix = "run."

  // MARK: Reading

  private static func openDirectory(_ path: String, what: String) throws -> Int32 {
    let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)

    guard descriptor >= 0 else {
      throw ControllerPackageError.io("cannot open \(what): \(errnoText())")
    }

    return descriptor
  }

  /// Opens a file by its packaged path, one component at a time. No component may be a link, and
  /// the file must be a plain file. A FIFO or a device never blocks the open.
  private static func openFile(_ path: String, in root: Int32) throws -> Int32 {
    var components = path.split(separator: "/").map(String.init)
    let name = components.removeLast()
    var directory = root
    var opened: [Int32] = []

    defer { for descriptor in opened { close(descriptor) } }

    for component in components {
      let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)

      guard next >= 0 else { throw refusal(path, errno) }

      opened.append(next)
      directory = next
    }

    let file = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)

    guard file >= 0 else { throw refusal(path, errno) }

    var info = stat()

    guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
      close(file)

      throw ControllerPackageError.contents("\(path) is not a plain file")
    }

    return file
  }

  private static func refusal(_ path: String, _ code: Int32) -> ControllerPackageError {
    switch code {
    case ENOENT: return .contents("\(path) is listed in controller.json and is missing")
    case ELOOP, ENOTDIR:
      return .contents("\(path) passes through a link, which a package may not hold")
    default: return .io("cannot open \(path): \(String(cString: strerror(code)))")
    }
  }

  static func readFile(_ path: String, in root: Int32, limit: Int) throws -> Data {
    let file = try openFile(path, in: root)

    defer { close(file) }

    var bytes = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)

    while true {
      let count = Darwin.read(file, &buffer, buffer.count)

      guard count >= 0 else {
        throw ControllerPackageError.io("cannot read \(path): \(errnoText())")
      }

      if count == 0 { return bytes }

      bytes.append(contentsOf: buffer[..<count])

      guard bytes.count <= limit else {
        throw ControllerPackageError.contents("\(path) is over \(limit) bytes")
      }
    }
  }

  private static func readOptionalFile(_ name: String, in root: Int32, limit: Int) throws -> Data? {
    var info = stat()

    guard fstatat(root, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
      guard errno == ENOENT else { throw refusal(name, errno) }

      return nil
    }

    return try readFile(name, in: root, limit: limit)
  }

  /// What a folder holds, as paths relative to it. A link or a special file anywhere throws.
  private static func listTree(_ root: Int32, what: String) throws -> (
    files: Set<String>, folders: Set<String>
  ) {
    var files = Set<String>()
    var folders = Set<String>()
    var count = 0

    func walk(_ directory: Int32, prefix: String, depth: Int) throws {
      guard depth <= ControllerDescriptor.maxPathDepth else {
        throw ControllerPackageError.contents("\(what) nests folders too deeply")
      }

      // A duplicate would share the folder's read offset, so a second listing of the same
      // folder would see nothing. A fresh open of "." gets an offset of its own.
      let copy = openat(directory, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)

      guard copy >= 0, let stream = fdopendir(copy) else {
        if copy >= 0 { close(copy) }

        throw ControllerPackageError.io("cannot list \(what): \(errnoText())")
      }

      defer { closedir(stream) }

      while let entry = readdir(stream) {
        let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
          String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
        }

        if name == "." || name == ".." { continue }

        count += 1

        guard count <= maxEntries else {
          throw ControllerPackageError.contents("\(what) holds more than \(maxEntries) entries")
        }

        let path = prefix.isEmpty ? name : prefix + "/" + name
        var info = stat()

        guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
          throw ControllerPackageError.io("cannot read \(path): \(errnoText())")
        }

        switch info.st_mode & S_IFMT {
        case S_IFREG:
          files.insert(path)

        case S_IFDIR:
          folders.insert(path)

          let child = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)

          guard child >= 0 else { throw refusal(path, errno) }

          defer { close(child) }

          try walk(child, prefix: path, depth: depth + 1)

        case S_IFLNK:
          throw ControllerPackageError.contents("\(path) is a link, which a package may not hold")

        default:
          throw ControllerPackageError.contents("\(path) is not a plain file or a folder")
        }
      }
    }

    try walk(root, prefix: "", depth: 0)

    return (files, folders)
  }

  /// The folder must hold the descriptor, the signature when there is one, and the listed files,
  /// and no other file. A file that is not listed could be code the descriptor does not cover.
  private static func checkTree(
    _ root: Int32, matches descriptor: ControllerDescriptor, signed: Bool, what: String
  ) throws {
    let tree = try listTree(root, what: what)
    var expected = Set(descriptor.files.keys)

    expected.insert(ControllerDescriptor.fileName)

    if signed { expected.insert(ControllerSignature.fileName) }

    if let unlisted = tree.files.subtracting(expected).sorted().first {
      throw ControllerPackageError.contents(
        "\(unlisted) is in the package and not listed in controller.json")
    }

    if let missing = expected.subtracting(tree.files).sorted().first {
      throw ControllerPackageError.contents(
        "\(missing) is listed in controller.json and is missing")
    }
  }

  // MARK: Writing

  private static func makeRunDirectory(in root: URL) throws -> URL {
    try prepareRunsRoot(root)

    var template = Array(root.appendingPathComponent(runPrefix + "XXXXXXXX").path.utf8CString)

    guard let made = mkdtemp(&template) else {
      throw ControllerPackageError.io("cannot make a snapshot folder: \(errnoText())")
    }

    return URL(fileURLWithPath: String(cString: made), isDirectory: true)
  }

  private static func writeFile(_ path: String, bytes: Data, in root: Int32, mode: mode_t) throws {
    var components = path.split(separator: "/").map(String.init)
    let name = components.removeLast()
    var directory = root
    var opened: [Int32] = []

    defer { for descriptor in opened { close(descriptor) } }

    for component in components {
      if mkdirat(directory, component, 0o700) != 0, errno != EEXIST {
        throw ControllerPackageError.io("cannot make the snapshot's \(component): \(errnoText())")
      }

      let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)

      guard next >= 0 else {
        throw ControllerPackageError.io("cannot open the snapshot's \(component): \(errnoText())")
      }

      opened.append(next)
      directory = next
    }

    let file = openat(
      directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)

    guard file >= 0 else {
      throw ControllerPackageError.io("cannot write the snapshot's \(path): \(errnoText())")
    }

    defer { close(file) }

    var offset = 0

    try bytes.withUnsafeBytes { raw in
      while offset < raw.count {
        let written = write(file, raw.baseAddress! + offset, raw.count - offset)

        guard written > 0 else {
          throw ControllerPackageError.io("cannot write the snapshot's \(path): \(errnoText())")
        }

        offset += written
      }
    }

    guard fchmod(file, mode) == 0 else {
      throw ControllerPackageError.io("cannot lock the snapshot's \(path): \(errnoText())")
    }
  }

  /// Walks the finished copy and reads it again, so what the run loads is checked as it sits.
  private static func verifyCopy(
    _ root: Int32, descriptorBytes: Data, signatureBytes: Data?
  ) throws {
    guard
      try readFile(ControllerDescriptor.fileName, in: root, limit: ControllerDescriptor.maxBytes)
        == descriptorBytes
    else { throw ControllerPackageError.contents("the snapshot's controller.json changed") }

    let descriptor = try ControllerDescriptor.parse(descriptorBytes)

    try checkTree(root, matches: descriptor, signed: signatureBytes != nil, what: "the snapshot")

    for (path, digest) in descriptor.files {
      let bytes = try readFile(path, in: root, limit: ControllerDescriptor.maxFileBytes)

      guard Data(SHA256.hash(data: bytes)) == digest else {
        throw ControllerPackageError.contents("the snapshot's \(path) does not match its digest")
      }
    }
  }

  /// Makes every folder of the snapshot read-only, the deepest first, and its top last.
  private static func lockFolders(_ root: Int32) throws {
    let tree = try listTree(root, what: "the snapshot")

    for folder in tree.folders.sorted(by: { $0.count > $1.count }) {
      guard fchmodat(root, folder, 0o500, AT_SYMLINK_NOFOLLOW) == 0 else {
        throw ControllerPackageError.io("cannot lock the snapshot's \(folder): \(errnoText())")
      }
    }

    guard fchmod(root, 0o500) == 0 else {
      throw ControllerPackageError.io("cannot lock the snapshot: \(errnoText())")
    }
  }

  /// Gives the owner write access to every folder again, then removes the tree. A link is removed
  /// as a link and never followed.
  static func removeTree(_ url: URL) {
    guard let enumerator = FileManager.default.enumerator(atPath: url.path) else { return }

    _ = chmod(url.path, 0o700)

    while let relative = enumerator.nextObject() as? String {
      let path = url.appendingPathComponent(relative).path
      var info = stat()

      if lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR {
        _ = chmod(path, 0o700)
      }
    }

    try? FileManager.default.removeItem(at: url)
  }
}
