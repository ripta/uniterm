import Darwin
import Foundation
import SourceAccess

/// A regular file opened read-only. It owns the descriptor, which the helper receives.
public final class OpenedImageFile: @unchecked Sendable {
  public let descriptor: Int32
  public let path: String
  public let modified: Double
  public let size: Int

  /// The real path of the opened descriptor, as the system reports it. It differs from `path` when
  /// a link led to the file. A controller is told about an image only when this lies in its scope.
  public let realPath: String?

  fileprivate init(descriptor: Int32, path: String, modified: Double, size: Int) {
    self.descriptor = descriptor
    self.path = path
    self.modified = modified
    self.size = size
    realPath = DescriptorPath.read(descriptor)
  }

  deinit {
    Darwin.close(descriptor)
  }

  public var name: String { (path as NSString).lastPathComponent }
}

/// A folder opened by descriptor. Listing it and opening its files go through that descriptor, so
/// replacing the path afterwards changes neither.
///
/// A folder a controller named is scoped. It keeps the scoped open it came from, and opens every
/// member through it, so a member that is a link out of the controller's scope is refused as any
/// other path is. Listing such a folder never follows a link, so it never looks at a target outside
/// the scope.
public final class OpenedFolder: @unchecked Sendable {
  public let path: String
  private let descriptor: Int32
  private let scoped: OpenedPath?

  fileprivate init(descriptor: Int32, path: String, scoped: OpenedPath? = nil) {
    self.descriptor = descriptor
    self.path = path
    self.scoped = scoped
  }

  /// Wraps a folder opened inside a controller's read scope. The folder's own descriptor is
  /// duplicated, and the scoped open stays with it for the members.
  public init?(scoped opened: OpenedPath, path: String) {
    guard case .folder = opened.kind else { return nil }

    let copy = dup(opened.fileDescriptor)

    guard copy >= 0 else { return nil }

    descriptor = copy
    self.path = path
    scoped = opened
  }

  deinit {
    Darwin.close(descriptor)
  }

  /// True when the folder opens its members through a controller's read scope.
  public var isScoped: Bool { scoped != nil }

  /// The images of the folder in `sort` order. Hidden files and subfolders are left out, and a
  /// file is an image when `types` says its name is one.
  public func list(supporting types: SupportedImageTypes, sort: ImageSort) -> Result<
    [ListedImage], SourceAccessError
  > {
    var images: [ListedImage] = []

    let result = scan(
      supporting: types, batchSize: 256, isCancelled: { false },
      deliver: { images.append(contentsOf: $0) })

    return result.map { FolderListing.sorted(images, by: sort) }
  }

  /// Reads the folder and hands the images over in batches of up to `batchSize`, in the order the
  /// disk gives them. A scan of a large folder reports as it goes, so the caller can show an image
  /// before the scan ends. It stops early when `isCancelled` says so.
  public func scan(
    supporting types: SupportedImageTypes, batchSize: Int, isCancelled: () -> Bool,
    deliver: ([ListedImage]) -> Void
  ) -> Result<Void, SourceAccessError> {
    let copy = dup(descriptor)

    guard copy >= 0, let stream = fdopendir(copy) else {
      let code = errno

      if copy >= 0 { Darwin.close(copy) }

      return .failure(.posix(code, path: path))
    }

    defer { closedir(stream) }

    rewinddir(stream)

    var batch: [ListedImage] = []

    var failure: Int32 = 0

    while true {
      errno = 0

      guard let entry = readdir(stream) else {
        failure = errno
        break
      }

      if isCancelled() { return .success(()) }

      let name = withUnsafePointer(to: &entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
          String(cString: $0)
        }
      }

      guard !name.hasPrefix("."), types.supports(fileName: name) else { continue }

      var info = stat()

      // A scoped folder never follows a link while it lists. Whether a link's target exists, and
      // what it is, would tell a controller about a file outside its scope. The link counts as an
      // image by its name, and opening it later goes through the scope.
      let follows = scoped == nil

      guard fstatat(descriptor, name, &info, follows ? 0 : AT_SYMLINK_NOFOLLOW) == 0 else {
        continue
      }

      let mode = info.st_mode & S_IFMT

      guard mode == S_IFREG || (!follows && mode == S_IFLNK) else { continue }

      batch.append(ListedImage(name: name, modified: Self.seconds(info.st_mtimespec)))

      if batch.count >= batchSize {
        deliver(batch)
        batch = []
      }
    }

    if !batch.isEmpty { deliver(batch) }

    return failure == 0 ? .success(()) : .failure(.posix(failure, path: path))
  }

  /// Opens the file named `name` in this folder. A name with a slash is refused.
  public func openFile(named name: String) -> Result<OpenedImageFile, SourceAccessError> {
    let full = (path as NSString).appendingPathComponent(name)

    guard !name.contains("/"), !name.isEmpty else { return .failure(.missing(path: full)) }

    if let scoped { return openScoped(named: name, in: scoped, full: full) }

    let file = openat(descriptor, name, O_RDONLY | O_NONBLOCK | O_CLOEXEC)

    guard file >= 0 else { return .failure(.posix(errno, path: full)) }

    return SourceOpener.regularFile(descriptor: file, path: full)
  }

  private func openScoped(named name: String, in scoped: OpenedPath, full: String) -> Result<
    OpenedImageFile, SourceAccessError
  > {
    switch scoped.openMemberBlocking(named: name) {
    case .failure(let error):
      switch error {
      case .missing: return .failure(.missing(path: full))
      case .denied: return .failure(.permissionDenied(path: full))
      default:
        return .failure(
          .unreadable(path: full, reason: "it is outside the folders the program may read"))
      }

    case .success(let member):
      guard case .file = member.kind else {
        return .failure(.notARegularFile(path: full, kind: "a folder"))
      }

      return SourceOpener.regularFile(descriptor: member.takeDescriptor(), path: full)
    }
  }

  static func seconds(_ time: timespec) -> Double {
    Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000
  }
}

public enum OpenedSource: Sendable {
  case file(OpenedImageFile)
  case folder(OpenedFolder)
}

/// Opens what the user named. It runs off the main thread.
public enum SourceOpener {
  /// Opens `path` read-only and non-blocking, so a named pipe never blocks the caller, then
  /// decides what it is from the descriptor. The path is never checked first, so a swap between a
  /// check and the open cannot slip a pipe or a device past the check.
  public static func open(path: String) -> Result<OpenedSource, SourceAccessError> {
    let descriptor = Darwin.open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)

    guard descriptor >= 0 else { return .failure(.posix(errno, path: path)) }

    var info = stat()

    guard fstat(descriptor, &info) == 0 else {
      let code = errno
      Darwin.close(descriptor)

      return .failure(.posix(code, path: path))
    }

    if info.st_mode & S_IFMT == S_IFDIR {
      return .success(.folder(OpenedFolder(descriptor: descriptor, path: path)))
    }

    return regularFile(descriptor: descriptor, path: path).map { .file($0) }
  }

  /// Takes ownership of `descriptor`. It is kept when it is a regular file, and closed otherwise.
  public static func regularFile(descriptor: Int32, path: String) -> Result<
    OpenedImageFile, SourceAccessError
  > {
    switch RegularFile.check(descriptor: descriptor, path: path) {
    case .failure(let error):
      return .failure(error)

    case .success(let info):
      return .success(
        OpenedImageFile(
          descriptor: descriptor, path: path, modified: OpenedFolder.seconds(info.modified),
          size: info.size))
    }
  }
}
