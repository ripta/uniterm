import Darwin
import Foundation

/// Why a path was not opened inside a read scope.
public enum ScopedOpenError: Error, Equatable, Sendable {
  /// The path is outside the scope, in a protected place the scope leaves out, or leads out of the
  /// scope through a link, or the scope holds no usable directory. This one answer also covers
  /// every failure that a path outside the scope could have. The caller learns nothing about
  /// whether the path exists, what it is, or whether macOS would have allowed it.
  case unavailable

  /// Inside the scope, nothing is there.
  case missing

  /// Inside the scope, it is neither a regular file nor a folder.
  case unsupported

  /// Inside the scope, the system refused the read.
  case denied

  /// Inside the scope, links nested deeper than the walk follows.
  case tooManyLinks

  /// The caller declared the power, but it does not stand for this run, as when the user allowed
  /// the run once. The caller knows its own grant, so this says nothing about any path.
  case notGranted
}

/// A file or folder opened inside a read scope.
///
/// The opened descriptor is the only way in. The path is not kept, so an applet that holds one
/// cannot open a different file by it. A folder opens its members through the scoped open again,
/// so a member that is a link out of the scope is refused like any other path.
///
/// Listing a folder and opening a member read the disk, so both are async and run off the calling
/// actor. Reading the descriptor is the holder's own work and has no bound here, so a holder on the
/// main thread reads it elsewhere.
public final class OpenedPath: @unchecked Sendable, Equatable {
  public enum Kind: Equatable, Sendable {
    case file(RegularFile.Info)
    case folder
  }

  public let kind: Kind

  private let lock = NSLock()
  private var descriptor: Int32
  private let scope: ReadScope
  private let protected: ProtectedLocations

  /// The scope's directories with their links resolved and their volumes asked, as they were when
  /// the path was opened. The walk that opened it resolved them off the main thread, so asking
  /// again later costs string work and one `F_GETPATH` on a descriptor that is already open.
  private let roots: [ScopedOpen.Root]

  init(
    descriptor: Int32, kind: Kind, scope: ReadScope, protected: ProtectedLocations,
    roots: [ScopedOpen.Root]
  ) {
    self.descriptor = descriptor
    self.kind = kind
    self.scope = scope
    self.protected = protected
    self.roots = roots
  }

  deinit {
    if descriptor >= 0 { Darwin.close(descriptor) }
  }

  public static func == (lhs: OpenedPath, rhs: OpenedPath) -> Bool {
    lhs === rhs
  }

  /// The descriptor, still owned by this object. It is -1 once `takeDescriptor` ran.
  public var fileDescriptor: Int32 {
    lock.withLock { descriptor }
  }

  /// Hands the descriptor over. The caller closes it, and this object closes nothing.
  public func takeDescriptor() -> Int32 {
    lock.withLock {
      let taken = descriptor
      descriptor = -1

      return taken
    }
  }

  /// True when `current` is the scope this path was opened under, and the descriptor's own real
  /// path lies in it right now. A grant that ended, or any other change to the scope, makes this
  /// false, so a command that waited for its turn under another grant is refused. A folder renamed
  /// out of the scope since the open does too.
  ///
  /// It does only string work and one `F_GETPATH` on the open descriptor, so the main thread may
  /// call it. It resolves nothing.
  public func isWithin(_ current: ReadScope?) -> Bool {
    guard let current, current == scope else { return false }

    let open = fileDescriptor

    return open >= 0 && ScopedOpen.holds(descriptor: open, roots: roots, protected: protected)
  }

  /// The names of a folder's members, sorted, at most `limit`. A file has none. The listing reads
  /// the disk off the calling actor, since a folder can sit on a slow volume.
  @concurrent
  public func memberNames(limit: Int = 10_000) async -> [String] {
    listMembers(limit: limit)
  }

  /// Opens one member of a folder through the scoped open, so the same checks apply as to any
  /// other path. A name with a separator, `.`, or `..` is refused. The walk runs off the calling
  /// actor.
  @concurrent
  public func openMember(named name: String) async -> Result<OpenedPath, ScopedOpenError> {
    openMemberNow(named: name)
  }

  func listMembers(limit: Int = 10_000) -> [String] {
    guard case .folder = kind else { return [] }

    let copy = dup(fileDescriptor)

    guard copy >= 0, let directory = fdopendir(copy) else {
      if copy >= 0 { Darwin.close(copy) }

      return []
    }

    defer { closedir(directory) }

    // The duplicate shares the folder's file offset, so an earlier listing left it at the end.
    rewinddir(directory)

    var names: [String] = []

    while let entry = readdir(directory), names.count < limit {
      let name = withUnsafePointer(to: &entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
      }

      if name != "." && name != ".." { names.append(name) }
    }

    return names.sorted()
  }

  func openMemberNow(named name: String) -> Result<OpenedPath, ScopedOpenError> {
    guard case .folder = kind, !name.isEmpty, name != ".", name != "..", !name.contains("/"),
      !name.utf8.contains(0), let path = ScopedOpen.realPath(of: fileDescriptor)
    else { return .failure(.unavailable) }

    return ScopedOpen.open(
      path: (path == "/" ? "" : path) + "/" + name, in: scope, protected: protected)
  }
}

/// Opens a path a controller named, inside the directories it may read, and touches nothing else.
///
/// The walk keeps a folder open and goes one name at a time with `openat` and no following. Before
/// it looks at a name, it checks that the name's path still lies in the scope, so nothing outside
/// the scope is ever looked up. A link is followed by splicing its target into the walk, and a
/// target outside the scope ends the walk before any of it is looked up. Only a regular file or a
/// folder is opened, from what `fstatat` said, and the descriptor is judged again once it is open.
/// The open never blocks and never makes a terminal device the controlling terminal. At the end the
/// descriptor's own real path is checked against the scope again, so a rename that raced the walk
/// cannot widen it.
///
/// Anything outside the scope gets one error, `unavailable`. A path outside the scope, one that
/// does not exist, and one a link leads out through look the same.
public enum ScopedOpen {
  static let maxLinks = 40

  /// A scope directory with its links resolved. The request is matched against it, and the walk
  /// starts in it.
  struct Root: Sendable {
    let written: [String]
    let resolved: [String]
    let resolvedPath: String
    let comparison: PathComparison
  }

  /// Opens `path` read-only. The caller owns the result.
  public static func open(
    path: String, in scope: ReadScope, protected: ProtectedLocations = .current
  ) -> Result<OpenedPath, ScopedOpenError> {
    open(path: path, in: scope, protected: protected, afterLookup: nil)
  }

  /// `afterLookup` runs after a name was looked at and before it is opened. A test uses it to
  /// change the disk in that gap.
  static func open(
    path: String, in scope: ReadScope, protected: ProtectedLocations,
    afterLookup: ((String) -> Void)?
  ) -> Result<OpenedPath, ScopedOpenError> {
    guard path.hasPrefix("/"), !path.utf8.contains(0), path.utf8.count <= ReadScope.maxPathBytes
    else { return .failure(.unavailable) }

    let protected = protected.resolvingLinks()
    let roots = roots(of: scope)

    guard !roots.isEmpty else { return .failure(.unavailable) }

    func allowed(_ names: [String]) -> Bool {
      roots.contains { root in
        root.comparison.isInside(names, root.resolved)
          && protected.place(
            holding: names, strictlyInside: root.resolved) == nil
      }
    }

    guard let start = start(of: names(of: path), roots: roots) else {
      return .failure(.unavailable)
    }

    var directory = Darwin.open(start.root.resolvedPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC)

    guard directory >= 0 else { return .failure(.unavailable) }

    var tracked = start.root.resolved
    var queue = start.rest
    var links = 0
    var handedOver = false

    defer { if !handedOver { Darwin.close(directory) } }

    while !queue.isEmpty {
      let part = queue.removeFirst()

      if part == "." { continue }

      if part == ".." {
        let parent = Array(tracked.dropLast())

        guard !tracked.isEmpty, allowed(parent) else { return .failure(.unavailable) }

        let next = openat(directory, "..", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)

        guard next >= 0 else { return .failure(.unavailable) }

        Darwin.close(directory)
        directory = next
        tracked = parent
        continue
      }

      let candidate = tracked + [part]

      guard allowed(candidate) else { return .failure(.unavailable) }

      var entry = stat()

      guard fstatat(directory, part, &entry, AT_SYMLINK_NOFOLLOW) == 0 else {
        return .failure(failure(errno))
      }

      afterLookup?(part)

      switch entry.st_mode & S_IFMT {
      case S_IFLNK:
        links += 1

        guard links <= maxLinks else { return .failure(.tooManyLinks) }

        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let length = readlinkat(directory, part, &buffer, Int(PATH_MAX))

        guard length > 0 else { return .failure(.unsupported) }

        let target = String(
          decoding: buffer[0..<length].map { UInt8(bitPattern: $0) }, as: UTF8.self)

        guard !target.utf8.contains(0) else { return .failure(.unavailable) }

        let spliced = names(of: target)

        if target.hasPrefix("/") {
          guard let again = self.start(of: spliced, roots: roots) else {
            return .failure(.unavailable)
          }

          let root = Darwin.open(again.root.resolvedPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC)

          guard root >= 0 else { return .failure(.unavailable) }

          Darwin.close(directory)
          directory = root
          tracked = again.root.resolved
          queue = again.rest + queue
        } else {
          queue = spliced + queue
        }

      case S_IFDIR:
        let next = openat(
          directory, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)

        guard next >= 0 else { return .failure(failure(errno)) }

        Darwin.close(directory)
        directory = next
        tracked = candidate

      case S_IFREG:
        guard queue.allSatisfy({ $0 == "." }) else { return .failure(.missing) }

        let file = openat(
          directory, part, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_NOCTTY | O_CLOEXEC)

        guard file >= 0 else { return .failure(failure(errno)) }

        return finish(descriptor: file, scope: scope, protected: protected, roots: roots)

      default:
        return .failure(queue.allSatisfy { $0 == "." } ? .unsupported : .missing)
      }
    }

    handedOver = true

    return finish(descriptor: directory, scope: scope, protected: protected, roots: roots)
  }

  /// True when the open descriptor's real path lies in the resolved `roots` now.
  static func holds(descriptor: Int32, roots: [Root], protected: ProtectedLocations) -> Bool {
    guard let real = realPath(of: descriptor), let names = PathComparison.plainComponents(of: real)
    else { return false }

    return roots.contains { root in
      root.comparison.isInside(names, root.resolved)
        && protected.place(holding: names, strictlyInside: root.resolved) == nil
    }
  }

  /// The real path of an open descriptor, as the system reports it.
  static func realPath(of descriptor: Int32) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)

    guard fcntl(descriptor, F_GETPATH, &buffer) == 0 else { return nil }

    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }

    return String(decoding: bytes, as: UTF8.self)
  }

  /// Judges an opened descriptor and keeps it, or closes it. It must be a regular file or a
  /// folder, and its own real path must lie in the scope.
  private static func finish(
    descriptor: Int32, scope: ReadScope, protected: ProtectedLocations, roots: [Root]
  ) -> Result<OpenedPath, ScopedOpenError> {
    var info = stat()

    guard fstat(descriptor, &info) == 0 else {
      Darwin.close(descriptor)

      return .failure(.unavailable)
    }

    let kind: OpenedPath.Kind

    switch info.st_mode & S_IFMT {
    case S_IFREG: kind = .file(.init(size: Int(info.st_size), modified: info.st_mtimespec))
    case S_IFDIR: kind = .folder
    default:
      Darwin.close(descriptor)

      return .failure(.unavailable)
    }

    guard let real = realPath(of: descriptor), let names = PathComparison.plainComponents(of: real),
      roots.contains(where: { root in
        root.comparison.isInside(names, root.resolved)
          && protected.place(
            holding: names, strictlyInside: root.resolved) == nil
      })
    else {
      Darwin.close(descriptor)

      return .failure(.unavailable)
    }

    return .success(
      OpenedPath(
        descriptor: descriptor, kind: kind, scope: scope, protected: protected, roots: roots))
  }

  /// The names of a path to walk, with empty names and `.` dropped. `..` stays, since the walk
  /// takes each one itself.
  private static func names(of path: String) -> [String] {
    path.split(separator: "/", omittingEmptySubsequences: true).map(String.init).filter {
      $0 != "."
    }
  }

  /// The scope's directories that exist, with their links resolved and their volumes asked.
  private static func roots(of scope: ReadScope) -> [Root] {
    scope.directories.compactMap { directory in
      guard let written = PathComparison.plainComponents(of: directory),
        let pointer = realpath(directory, nil)
      else { return nil }

      defer { free(pointer) }

      let resolvedPath = String(cString: pointer)

      guard let resolved = PathComparison.plainComponents(of: resolvedPath) else { return nil }

      return Root(
        written: written, resolved: resolved, resolvedPath: resolvedPath,
        comparison: PathComparison.ofVolume(at: resolvedPath))
    }
  }

  /// The root a path begins in, as written or with its links resolved, and what is left of the
  /// path after it. The longest match wins. A path that climbs inside the part a root names
  /// matches nothing.
  private static func start(of target: [String], roots: [Root]) -> (root: Root, rest: [String])? {
    var best: (root: Root, rest: [String])?
    var bestLength = -1

    for root in roots {
      for form in [root.written, root.resolved] {
        guard target.count >= form.count, !target[0..<form.count].contains(".."),
          root.comparison.isInside(target, form), form.count > bestLength
        else { continue }

        best = (root, Array(target[form.count...]))
        bestLength = form.count
      }
    }

    return best
  }

  private static func failure(_ code: Int32) -> ScopedOpenError {
    switch code {
    case ENOENT, ENOTDIR: return .missing
    case EACCES, EPERM: return .denied
    default: return .unavailable
    }
  }
}
