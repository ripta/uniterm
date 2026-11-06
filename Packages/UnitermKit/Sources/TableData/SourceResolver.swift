import Darwin
import Foundation

/// The file a pane opens, and the bookmark that finds it again after a move.
public struct ResolvedSource: Sendable, Equatable {
  public let file: URL

  /// The bookmark to store. It names `file`.
  public let bookmark: Data?

  /// Set when the stored path was missing and the bookmark found the file elsewhere.
  public let movedFrom: String?
}

/// Turns a stored path and bookmark into the file to open. It touches the disk, so callers run it
/// off the main thread.
///
/// The stored path wins while a path is there, because it is what the user named. A bookmark follows
/// the file's identity, so it would show a backup that a renderer rotated away instead of the fresh
/// file at the same path. The bookmark is used only when the path is missing, and it never mounts a
/// volume or asks the user anything. The bookmark is made again whenever it does not name the file
/// that opened, or when the system reports it stale.
public enum SourceResolver {
  @concurrent
  public static func resolve(path: String, bookmark: Data?) async -> Result<
    ResolvedSource, TableLoadError
  > {
    resolveBlocking(path: path, bookmark: bookmark)
  }

  public static func resolveBlocking(path: String, bookmark: Data?) -> Result<
    ResolvedSource, TableLoadError
  > {
    var info = stat()

    if stat(path, &info) == 0 {
      let url = URL(fileURLWithPath: path)
      return .success(
        ResolvedSource(
          file: url, bookmark: refreshedBookmark(for: url, identity: info, stored: bookmark),
          movedFrom: nil))
    }

    let code = errno

    guard code == ENOENT || code == ENOTDIR, let bookmark else {
      return .failure(.posix(code, path: path))
    }

    var stale = false

    guard
      let moved = try? URL(
        resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil,
        bookmarkDataIsStale: &stale),
      stat(moved.path, &info) == 0
    else {
      return .failure(.missing(path: path))
    }

    return .success(
      ResolvedSource(
        file: moved, bookmark: refreshedBookmark(for: moved, identity: info, stored: bookmark),
        movedFrom: moved.path))
  }

  /// The stored bookmark if it names the file at `identity` and is not stale. A new one otherwise.
  private static func refreshedBookmark(for url: URL, identity: stat, stored: Data?) -> Data? {
    if let stored {
      var stale = false
      var other = stat()

      if let named = try? URL(
        resolvingBookmarkData: stored, options: [.withoutUI, .withoutMounting], relativeTo: nil,
        bookmarkDataIsStale: &stale),
        !stale, stat(named.path, &other) == 0, other.st_dev == identity.st_dev,
        other.st_ino == identity.st_ino
      {
        return stored
      }
    }

    return try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
  }
}
