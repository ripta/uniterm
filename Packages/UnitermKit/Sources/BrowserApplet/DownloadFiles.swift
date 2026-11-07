import BrowserModel
import CoreServices
import Darwin
import Foundation

/// The file work a download does, which can wait on a network or iCloud volume. Each runs off the
/// main thread, and its result comes back as a later event, so the main thread never waits on it.
/// The browser uses `live`. A test supplies its own to hold an operation, and to see which thread
/// ran it.
public struct DownloadFileOperations: Sendable {
  public var prepareFolder: @Sendable (URL) throws -> Void
  public var finish:
    @Sendable (
      _ temporary: URL, _ name: String, _ folder: URL, _ origin: URL?, _ source: URL?
    ) throws -> URL
  public var discard: @Sendable (URL) -> Void
  public var sweep: @Sendable (_ folder: URL, _ now: Date) -> Void

  public init(
    prepareFolder: @escaping @Sendable (URL) throws -> Void,
    finish: @escaping @Sendable (URL, String, URL, URL?, URL?) throws -> URL,
    discard: @escaping @Sendable (URL) -> Void,
    sweep: @escaping @Sendable (URL, Date) -> Void
  ) {
    self.prepareFolder = prepareFolder
    self.finish = finish
    self.discard = discard
    self.sweep = sweep
  }

  public static let live = DownloadFileOperations(
    prepareFolder: {
      try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true)
    },
    finish: {
      try DownloadFiles.finish(
        temporary: $0, name: $1, in: $2, origin: $3, source: $4)
    },
    discard: { DownloadFiles.discard($0) },
    sweep: { DownloadFiles.sweepStale(in: $0, now: $1) })
}

/// Remembers which folders the browser has already swept this launch, so the sweep runs at the
/// first download into a folder and no later one. Every pane shares one.
@MainActor
public final class DownloadSweeper {
  private var swept: Set<String> = []

  public init() {}

  /// True the first time it is asked about `folder`.
  func shouldSweep(_ folder: URL) -> Bool {
    swept.insert(folder.standardizedFileURL.path(percentEncoded: false)).inserted
  }
}

/// What a download leaves on disk. It has no WebKit in it, so a test drives it with plain files.
///
/// A download writes under a hidden temporary name. The final name appears in one step, when the
/// file is complete and already marked as downloaded, so a crash never leaves a file that looks
/// complete or a complete file that skips Gatekeeper.
enum DownloadFiles {
  enum Failure: Error, LocalizedError, Equatable {
    /// The system refused to record where the file came from. A file with no mark would skip
    /// Gatekeeper's check, so the download fails instead.
    case quarantine(String)

    /// Every numbered name up to the limit is taken.
    case noFreeName

    case rename(String)

    var errorDescription: String? {
      switch self {
      case .quarantine(let reason):
        return
          "The file could not be marked as downloaded from the internet, which a folder or volume "
          + "without extended attributes cannot do. \(reason)"

      case .noFreeName:
        return "Every numbered copy of the name is already taken."

      case .rename(let reason):
        return "The file could not be moved into place. \(reason)"
      }
    }
  }

  /// How many numbered names one download tries before it gives up. A policy value.
  static let attemptLimit = 100_000

  static let temporaryPrefix = ".uniterm-download-"
  static let temporarySuffix = ".part"

  /// Names the app that wrote the file, in the quarantine record.
  static let agentName = "uniterm"

  /// The bundle identifier the quarantine record names. A process with no bundle, such as a test
  /// runner, names its own.
  static var agentBundleIdentifier: String {
    Bundle.main.bundleIdentifier ?? "dev.uniterm.app"
  }

  /// A name no other download takes, since it carries a fresh identifier. The file does not exist
  /// yet, which is what `WKDownload` needs of its destination.
  static func temporaryURL(in directory: URL) -> URL {
    directory.appending(
      path: "\(temporaryPrefix)\(UUID().uuidString)\(temporarySuffix)", directoryHint: .notDirectory
    )
  }

  /// The quarantine record for a finished file. A `data:` address is the file's own bytes, and
  /// the record would carry all of them, so it names no data address.
  static func quarantineProperties(origin: URL?, source: URL?) -> [String: Any] {
    var properties: [String: Any] = [
      kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
      kLSQuarantineAgentBundleIdentifierKey as String: agentBundleIdentifier,
      kLSQuarantineAgentNameKey as String: agentName,
    ]

    if let origin, let kept = recordable(origin) {
      properties[kLSQuarantineOriginURLKey as String] = kept
    }

    if let source, let kept = recordable(source) {
      properties[kLSQuarantineDataURLKey as String] = kept
    }

    return properties
  }

  /// Marks `temporary`, then gives it the first free numbered form of `name` in `directory`. The
  /// rename fails when the name exists, so two downloads, in any pane or window, never take the
  /// same name. A check followed by a rename would let both pass the check.
  static func finish(
    temporary: URL, name: String, in directory: URL, origin: URL?, source: URL?
  ) throws -> URL {
    do {
      var values = URLResourceValues()
      values.quarantineProperties = quarantineProperties(origin: origin, source: source)

      var marked = temporary
      try marked.setResourceValues(values)
    } catch {
      throw Failure.quarantine(error.localizedDescription)
    }

    for attempt in 1...attemptLimit {
      let candidate = directory.appending(
        path: DownloadName.numbered(name, attempt: attempt), directoryHint: .notDirectory)

      let status = temporary.withUnsafeFileSystemRepresentation { from in
        candidate.withUnsafeFileSystemRepresentation { to in
          guard let from, let to else { return EINVAL }

          return renamex_np(from, to, UInt32(RENAME_EXCL)) == 0 ? 0 : errno
        }
      }

      switch status {
      case 0:
        return candidate

      case EEXIST:
        continue

      default:
        throw Failure.rename(String(cString: strerror(status)))
      }
    }

    throw Failure.noFreeName
  }

  /// How old a leftover temporary file must be before a sweep removes it. A second instance of the
  /// app may still be writing a download, so the age is generous.
  static let staleAge: TimeInterval = 7 * 24 * 60 * 60

  /// Whether `name` is exactly what `temporaryURL` makes: the prefix, an uppercase UUID, and the
  /// suffix. A user's file that only resembles it is never matched.
  static func isTemporaryName(_ name: String) -> Bool {
    guard name.hasPrefix(temporaryPrefix), name.hasSuffix(temporarySuffix),
      name.count > temporaryPrefix.count + temporarySuffix.count
    else { return false }

    let middle = String(name.dropFirst(temporaryPrefix.count).dropLast(temporarySuffix.count))

    return UUID(uuidString: middle)?.uuidString == middle
  }

  /// Removes the temporary files a crash or a quit left in `folder`: regular files of the exact
  /// temporary name that were last written more than `age` before `now`. Returns how many it
  /// removed. It never follows a symbolic link and never touches another name.
  @discardableResult
  static func sweepStale(in folder: URL, olderThan age: TimeInterval = staleAge, now: Date) -> Int {
    let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
    let urls =
      (try? FileManager.default.contentsOfDirectory(
        at: folder, includingPropertiesForKeys: keys, options: [])) ?? []
    var removed = 0

    for url in urls where isTemporaryName(url.lastPathComponent) {
      guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
        let modified = values.contentModificationDate, now.timeIntervalSince(modified) > age
      else { continue }

      if (try? FileManager.default.removeItem(at: url)) != nil { removed += 1 }
    }

    return removed
  }

  /// Removes a partial file. A file that is already gone is the goal, so that is no error.
  static func discard(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
  }

  /// An address the record may carry. A very long one is dropped, since the record is an
  /// extended attribute with a small room.
  private static func recordable(_ url: URL) -> URL? {
    guard url.scheme?.lowercased() != "data", url.absoluteString.utf8.count <= 2048 else {
      return nil
    }

    return url
  }
}
