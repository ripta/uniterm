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

/// A source, found and opened, with what is known about its folder.
///
/// The listing is not part of it. A folder is scanned after the load, so the pane can show an
/// image before the scan ends.
public struct LoadedSource: Sendable {
  public let resolved: ResolvedSource
  public let kind: SourceKind

  /// The folder to scan. A single file's folder is scanned too, so its siblings can be stepped
  /// through. Nil when that folder cannot be opened.
  public let folder: OpenedFolder?

  /// True when a single file's folder could not be opened, for example under macOS privacy
  /// protection. The pane shows the file and cannot step.
  public let folderNotListed: Bool

  /// The image to show now. Nil when only the scan can say which one, as for a folder opened
  /// fresh, or a restore whose stored image is gone.
  public let image: OpenedImageFile?
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

  /// Opens the image named `name` in `folder` off the calling thread, as a step or a prefetch
  /// does. A file deleted since the scan reports as missing.
  @concurrent
  public static func openImage(in folder: OpenedFolder, named name: String) async -> Result<
    OpenedImageFile, SourceAccessError
  > {
    folder.openFile(named: name)
  }

  public static func loadBlocking(
    path: String, bookmark: Data?, storedKind: SourceKind?, wanted: WantedImage?,
    sort: ImageSort, types: SupportedImageTypes
  ) -> Result<LoadedSource, SourceLoadFailure> {
    var resolved: ResolvedSource

    switch SourceResolver.resolveBlocking(path: path, bookmark: bookmark) {
    case .success(let found):
      resolved = found

    case .failure(let error):
      guard storedKind == .file, let sibling = siblingInOldFolder(of: path, wanted: wanted) else {
        return .failure(.access(error))
      }

      resolved = sibling
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

      return loadFile(file, resolved: resolved, wanted: wanted, types: types)

    case .folder(let folder):
      var image: OpenedImageFile?

      if let wanted, types.supports(fileName: wanted.name),
        case .success(let file) = folder.openFile(named: wanted.name)
      {
        image = file
      }

      return .success(
        LoadedSource(
          resolved: resolved, kind: .folder, folder: folder, folderNotListed: false, image: image))
    }
  }

  /// A file opened by the user, or restored. Its folder is opened so the scan can list its siblings.
  /// A restore asks for the image that was showing, which may be a sibling of the stored file.
  private static func loadFile(
    _ file: OpenedImageFile, resolved: ResolvedSource, wanted: WantedImage?,
    types: SupportedImageTypes
  ) -> Result<LoadedSource, SourceLoadFailure> {
    let parent = (file.path as NSString).deletingLastPathComponent

    guard case .success(.folder(let folder)) = SourceOpener.open(path: parent) else {
      return .success(
        LoadedSource(
          resolved: resolved, kind: .file, folder: nil, folderNotListed: true, image: file))
    }

    var image: OpenedImageFile? = file

    if let wanted, wanted.name != file.name {
      image = nil

      if types.supports(fileName: wanted.name),
        case .success(let sibling) = folder.openFile(named: wanted.name)
      {
        image = sibling
      }
    }

    return .success(
      LoadedSource(
        resolved: resolved, kind: .file, folder: folder, folderNotListed: false, image: image))
  }

  /// The wanted image in the folder the stored path used to be in, when the stored file and its
  /// bookmark are both gone. The result names that image as where the source moved to.
  private static func siblingInOldFolder(of path: String, wanted: WantedImage?)
    -> ResolvedSource?
  {
    guard let wanted, !wanted.name.contains("/"), !wanted.name.isEmpty else { return nil }

    let candidate = ((path as NSString).deletingLastPathComponent as NSString)
      .appendingPathComponent(wanted.name)

    guard case .success(let found) = SourceResolver.resolveBlocking(path: candidate, bookmark: nil)
    else { return nil }

    return ResolvedSource(file: found.file, bookmark: found.bookmark, movedFrom: candidate)
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
