import AtomicFile
import Darwin
import Foundation

public enum LayoutStoreError: Error, CustomStringConvertible {
  /// This instance does not hold the lock on the layout folder, so it must not read or write.
  case notWriter

  case directory(String, Int32)
  case write(String, Int32)
  case keepAside(String, any Error)
  case read(String, any Error)

  public var description: String {
    switch self {
    case .notWriter:
      return "another uniterm owns the layout, so this instance does not save it"

    case .directory(let path, let code):
      return "could not prepare \(path): \(String(cString: strerror(code)))"

    case .write(let path, let code):
      return "could not write \(path): \(String(cString: strerror(code)))"

    case .keepAside(let path, let error):
      return "could not keep \(path) aside: \(error.localizedDescription)"

    case .read(let path, let error):
      return "could not read \(path): \(error.localizedDescription)"
    }
  }
}

/// The bounds of recovery.
public struct LayoutStorePolicy: Sendable, Equatable {
  /// How many launches in a row may end before they finish. Once this many have, the next launch
  /// moves the layout aside and starts a default one.
  public var crashedLaunchBound: Int

  /// How many kept-aside files stay. The oldest go first.
  public var keepAsideLimit: Int

  public init(crashedLaunchBound: Int, keepAsideLimit: Int) {
    self.crashedLaunchBound = crashedLaunchBound
    self.keepAsideLimit = keepAsideLimit
  }

  public static let standard = LayoutStorePolicy(crashedLaunchBound: 3, keepAsideLimit: 5)
}

/// What a launch found.
public enum LaunchResult: Sendable, Equatable {
  /// A layout to restore.
  case restored(SavedLayout)

  /// Start a default layout. The notice, when there is one, says why a saved file was set aside.
  case fresh(notice: String?)
}

/// The layout file in `~/Library/Application Support/uniterm/`, and everything that keeps it safe.
///
/// One running instance owns the directory, through an exclusive lock. A second instance does not
/// get the lock and never writes. Writes go to a temp file and then rename over the layout, so a
/// crash leaves either the old file or the new one. The file, every temp file, and the directory
/// are private to the user.
///
/// A launch marker counts launches that did not finish. A file that cannot be read, or that comes
/// from a newer build, is moved aside and never overwritten. So is the file of a launch that keeps
/// crashing while it restores. Kept-aside files are numbered, so none replaces another, and only
/// the newest few stay.
///
/// All calls are meant for one thread at a time.
public final class LayoutStore {
  public let directory: URL

  private let policy: LayoutStorePolicy
  private let migrations: LayoutMigrations
  private var lockDescriptor: Int32 = -1

  public init(
    directory: URL, policy: LayoutStorePolicy = .standard,
    migrations: LayoutMigrations = .standard
  ) {
    self.directory = directory
    self.policy = policy
    self.migrations = migrations
  }

  deinit {
    if lockDescriptor >= 0 { close(lockDescriptor) }
  }

  /// `~/Library/Application Support/uniterm`.
  public static func defaultDirectory() throws -> URL {
    let support = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)

    return support.appendingPathComponent("uniterm", isDirectory: true)
  }

  var layoutURL: URL { directory.appendingPathComponent("layout.json") }
  var markerURL: URL { directory.appendingPathComponent("launch.marker") }
  private var lockURL: URL { directory.appendingPathComponent("layout.lock") }

  // MARK: Ownership

  public var isWriter: Bool { lockDescriptor >= 0 }

  /// Takes the single-writer lock. Returns false when another running instance holds it. The
  /// caller then never saves. Throws when the directory cannot be made private.
  public func acquire() throws -> Bool {
    guard !isWriter else { return true }

    do {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    } catch {
      throw LayoutStoreError.directory(
        directory.path, Int32(truncatingIfNeeded: (error as NSError).code))
    }

    guard chmod(directory.path, 0o700) == 0 else {
      throw LayoutStoreError.directory(directory.path, errno)
    }

    let descriptor = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)

    guard descriptor >= 0 else { throw LayoutStoreError.directory(lockURL.path, errno) }

    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      let code = errno
      close(descriptor)

      if code == EWOULDBLOCK { return false }

      throw LayoutStoreError.directory(lockURL.path, code)
    }

    lockDescriptor = descriptor
    removeStaleTempFiles()
    return true
  }

  /// Lets go of the lock.
  public func release() {
    guard lockDescriptor >= 0 else { return }

    close(lockDescriptor)
    lockDescriptor = -1
  }

  // MARK: Launch

  /// Starts a launch. It reads the layout, then sets the launch marker. Call `finishLaunch()` once
  /// the windows are up.
  ///
  /// The marker counts launches that never finished. At the bound, the layout is moved aside and
  /// the launch starts fresh. A layout that is unreadable or newer is moved aside too.
  public func beginLaunch() throws -> LaunchResult {
    guard isWriter else { throw LayoutStoreError.notWriter }

    let unfinished = readMarker()

    if unfinished >= policy.crashedLaunchBound {
      let kept = try moveLayoutAside()
      try writeMarker(1)

      return .fresh(
        notice: kept.map {
          "uniterm did not finish starting \(unfinished) times in a row, so the saved layout was kept as \($0.lastPathComponent) and a new layout started."
        })
    }

    let result = try readLayout()

    try writeMarker(unfinished + 1)
    return result
  }

  /// Reads the layout file. A file that cannot be used is moved aside, and the launch starts fresh.
  /// Every failure here comes before the marker is written, because a launch that threw never
  /// started and must not count toward the crash bound.
  private func readLayout() throws -> LaunchResult {
    guard FileManager.default.fileExists(atPath: layoutURL.path) else {
      return .fresh(notice: nil)
    }

    let data: Data
    do {
      data = try Data(contentsOf: layoutURL)
    } catch {
      throw LayoutStoreError.read(layoutURL.path, error)
    }

    do {
      return .restored(try LayoutCodec.decode(data, migrations: migrations))
    } catch {
      let kept = try moveLayoutAside()
      let name = kept?.lastPathComponent ?? "layout.json"

      return .fresh(
        notice:
          "The saved layout could not be used (\(error)). It was kept as \(name), and a new layout started."
      )
    }
  }

  /// Ends a launch that got as far as showing its windows.
  public func finishLaunch() {
    try? FileManager.default.removeItem(at: markerURL)
  }

  // MARK: Saving

  /// Writes the layout. Throws when the write fails, and leaves the old file in place.
  public func save(_ layout: SavedLayout) throws {
    guard isWriter else { throw LayoutStoreError.notWriter }

    try writeAtomically(try LayoutCodec.encode(layout), to: layoutURL)
  }

  /// Keeps a copy of the current file beside it, for a launch that could not restore everything.
  @discardableResult
  public func keepCopyAside() throws -> URL? {
    guard FileManager.default.fileExists(atPath: layoutURL.path) else { return nil }

    let target = nextAsideURL()

    do {
      try FileManager.default.copyItem(at: layoutURL, to: target)
    } catch {
      throw LayoutStoreError.keepAside(layoutURL.path, error)
    }

    chmod(target.path, 0o600)
    pruneKeptAside()
    return target
  }

  // MARK: Kept-aside files

  private static let asidePrefix = "layout.aside-"
  private static let asideSuffix = ".json"

  /// The kept-aside files, oldest first.
  var keptAsideFiles: [URL] {
    asideEntries().map(\.url)
  }

  private func asideEntries() -> [(index: Int, url: URL)] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []

    return names.compactMap { name in
      guard name.hasPrefix(Self.asidePrefix), name.hasSuffix(Self.asideSuffix) else { return nil }

      let digits = name.dropFirst(Self.asidePrefix.count).dropLast(Self.asideSuffix.count)

      guard let index = Int(digits) else { return nil }

      return (index, directory.appendingPathComponent(name))
    }.sorted { $0.index < $1.index }
  }

  /// A name no kept-aside file has had, so a new one never replaces an old one.
  private func nextAsideURL() -> URL {
    let next = (asideEntries().last?.index ?? 0) + 1
    return directory.appendingPathComponent("\(Self.asidePrefix)\(next)\(Self.asideSuffix)")
  }

  /// Moves the layout file aside. Returns where it went, or nil when there was no file.
  private func moveLayoutAside() throws -> URL? {
    guard FileManager.default.fileExists(atPath: layoutURL.path) else { return nil }

    let target = nextAsideURL()

    do {
      try FileManager.default.moveItem(at: layoutURL, to: target)
    } catch {
      throw LayoutStoreError.keepAside(layoutURL.path, error)
    }

    pruneKeptAside()
    return target
  }

  private func pruneKeptAside() {
    let entries = asideEntries()

    guard entries.count > policy.keepAsideLimit else { return }

    for entry in entries.prefix(entries.count - policy.keepAsideLimit) {
      try? FileManager.default.removeItem(at: entry.url)
    }
  }

  // MARK: Marker

  /// How many launches began and never finished. A marker that cannot be read counts as one.
  private func readMarker() -> Int {
    guard let data = try? Data(contentsOf: markerURL) else { return 0 }

    return Int(
      String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
      ?? 1
  }

  private func writeMarker(_ count: Int) throws {
    try writeAtomically(Data("\(count)\n".utf8), to: markerURL)
  }

  // MARK: Files

  private func removeStaleTempFiles() {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []

    for name in names where name.contains(AtomicFile.tempMarker) {
      try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }
  }

  /// Writes through the shared atomic writer, so a crash leaves the old file or the new one.
  private func writeAtomically(_ data: Data, to url: URL) throws {
    do {
      try AtomicFile.write(data, to: url)
    } catch {
      throw LayoutStoreError.write(error.path, error.code)
    }
  }
}
