import Darwin
import Foundation
import SourceAccess

/// Whether a source is one image or a folder of them.
public enum SourceKind: String, Codable, Sendable, Equatable {
  case file
  case folder
}

/// The image a restore or a reload wants back.
public struct WantedImage: Sendable, Equatable {
  public var name: String
  public var modified: Double?

  public init(name: String, modified: Double?) {
    self.name = name
    self.modified = modified
  }
}

/// A source, found and opened, with the image to show first.
public struct LoadedSource: Sendable {
  public let resolved: ResolvedSource
  public let kind: SourceKind
  public let folder: OpenedFolder?
  public let listing: [ListedImage]
  public let index: Int?

  /// The first image, opened for the helper. Nil when the folder holds none.
  public let file: OpenedImageFile?
}

public enum SourceLoadFailure: Error, Sendable, Equatable, LocalizedError {
  case access(SourceAccessError)
  case notAnImage(name: String)
  case noImages(folder: String)
  case kindChanged(path: String, expected: SourceKind)

  public var errorDescription: String? {
    switch self {
    case .access(let error):
      return error.errorDescription

    case .notAnImage(let name):
      return "\u{201C}\(name)\u{201D} is not an image uniterm can show."

    case .noImages(let folder):
      return "\u{201C}\(SourceAccessError.name(of: folder))\u{201D} has no images in it."

    case .kindChanged(let path, let expected):
      let now = expected == .folder ? "a file" : "a folder"
      let was = expected == .folder ? "a folder" : "a file"

      return "\u{201C}\(SourceAccessError.name(of: path))\u{201D} is now \(now). It was \(was)."
    }
  }
}

/// Finds, opens, and lists a source. It touches the disk, so callers run it off the main thread.
public enum SourceLoader {
  @concurrent
  public static func load(
    path: String, bookmark: Data?, storedKind: SourceKind?, wanted: WantedImage?,
    sort: ImageSort, types: SupportedImageTypes
  ) async -> Result<LoadedSource, SourceLoadFailure> {
    loadBlocking(
      path: path, bookmark: bookmark, storedKind: storedKind, wanted: wanted, sort: sort,
      types: types)
  }

  public static func loadBlocking(
    path: String, bookmark: Data?, storedKind: SourceKind?, wanted: WantedImage?,
    sort: ImageSort, types: SupportedImageTypes
  ) -> Result<LoadedSource, SourceLoadFailure> {
    var resolved: ResolvedSource

    switch SourceResolver.resolveBlocking(path: path, bookmark: bookmark) {
    case .success(let found): resolved = found
    case .failure(let error): return .failure(.access(error))
    }

    var opened: OpenedSource

    switch SourceOpener.open(path: resolved.file.path) {
    case .success(let source): opened = source
    case .failure(let error): return .failure(.access(error))
    }

    if let storedKind, kind(of: opened) != storedKind {
      guard let moved = bookmarkTarget(bookmark, differentFrom: resolved.file.path),
        case .success(let source) = SourceOpener.open(path: moved.path),
        kind(of: source) == storedKind
      else {
        return .failure(.kindChanged(path: path, expected: storedKind))
      }

      opened = source
      resolved = ResolvedSource(file: moved, bookmark: bookmark, movedFrom: moved.path)
    }

    switch opened {
    case .file(let file):
      guard types.supports(fileName: file.name) else {
        return .failure(.notAnImage(name: file.name))
      }

      return .success(
        LoadedSource(
          resolved: resolved, kind: .file, folder: nil,
          listing: [ListedImage(name: file.name, modified: file.modified)], index: 0, file: file))

    case .folder(let folder):
      return loadFolder(folder, resolved: resolved, wanted: wanted, sort: sort, types: types)
    }
  }

  private static func loadFolder(
    _ folder: OpenedFolder, resolved: ResolvedSource, wanted: WantedImage?, sort: ImageSort,
    types: SupportedImageTypes
  ) -> Result<LoadedSource, SourceLoadFailure> {
    var listing: [ListedImage]

    switch folder.list(supporting: types, sort: sort) {
    case .success(let images): listing = images
    case .failure(let error): return .failure(.access(error))
    }

    guard !listing.isEmpty else { return .failure(.noImages(folder: folder.path)) }

    var index =
      wanted.flatMap {
        FolderListing.nearest(toName: $0.name, modified: $0.modified, in: listing, sort: sort)
      } ?? 0

    while !listing.isEmpty {
      switch folder.openFile(named: listing[index].name) {
      case .success(let file):
        return .success(
          LoadedSource(
            resolved: resolved, kind: .folder, folder: folder, listing: listing, index: index,
            file: file))

      case .failure:
        listing.remove(at: index)
        index = min(index, listing.count - 1)
      }
    }

    return .failure(.noImages(folder: folder.path))
  }

  private static func kind(of source: OpenedSource) -> SourceKind {
    switch source {
    case .file: return .file
    case .folder: return .folder
    }
  }

  private static func bookmarkTarget(_ bookmark: Data?, differentFrom path: String) -> URL? {
    guard let bookmark else { return nil }

    var stale = false

    guard
      let url = try? URL(
        resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil,
        bookmarkDataIsStale: &stale),
      url.path != path
    else { return nil }

    return url
  }
}
