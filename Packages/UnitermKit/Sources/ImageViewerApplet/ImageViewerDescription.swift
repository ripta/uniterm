import AppletKit
import Foundation
import ImageViewerModel

/// The restorable state of an image viewer.
///
/// It is inert, and it holds no image data. A restored pane opens the source again. It names the
/// source by path first and by bookmark when the path is gone, and it remembers which image was
/// showing and how the folder was ordered.
public struct ImageViewerDescription: Codable, Equatable, Sendable {
  public static let typeID = "image-viewer"

  /// The version of the payload this build reads and writes. A change an older build cannot
  /// round-trip bumps it.
  public static let currentVersion = 1

  /// The directory the pane started in. An empty pane reports it as its current directory.
  public var startDirectory: String?

  /// The opened source's absolute path, a file or a folder, as the user named it.
  public var path: String?

  /// Whether `path` named a file or a folder when it was opened.
  public var kind: SourceKind?

  /// A macOS bookmark of the source. It finds the source after a move or a rename.
  public var bookmark: Data?

  /// The file name of the image showing, and its modification time from the listing. Together they
  /// place a deleted image in the folder's order.
  public var current: String?
  public var currentModified: Double?

  public var sort: ImageSort

  public init(
    startDirectory: String? = nil, path: String? = nil, kind: SourceKind? = nil,
    bookmark: Data? = nil, current: String? = nil, currentModified: Double? = nil,
    sort: ImageSort = .name
  ) {
    self.startDirectory = startDirectory
    self.path = path
    self.kind = kind
    self.bookmark = bookmark
    self.current = current
    self.currentModified = currentModified
    self.sort = sort
  }

  public func appletDescription() throws -> AppletDescription {
    AppletDescription(
      type: Self.typeID, version: Self.currentVersion, payload: try JSONValue(encoding: self))
  }

  /// Reads a description. A description of another type, a newer version, or a shape that does not
  /// decode is refused, and the caller keeps the original.
  public static func decode(_ description: AppletDescription) throws -> ImageViewerDescription {
    guard description.type == typeID else {
      throw AppletRestoreError.wrongType(expected: typeID, found: description.type)
    }

    guard description.version <= currentVersion else {
      throw AppletRestoreError.newerVersion(found: description.version, supported: currentVersion)
    }

    let decoded: ImageViewerDescription
    do {
      decoded = try description.payload.decoded(as: ImageViewerDescription.self)
    } catch {
      throw AppletRestoreError.corrupt("image viewer description: \(error)")
    }

    if let path = decoded.path, !path.hasPrefix("/") {
      throw AppletRestoreError.corrupt("image viewer description names a relative path")
    }

    if let start = decoded.startDirectory, !start.hasPrefix("/") {
      throw AppletRestoreError.corrupt("image viewer description starts in a relative path")
    }

    if let current = decoded.current, current.contains("/") || current.isEmpty {
      throw AppletRestoreError.corrupt(
        "image viewer description names a current image with a slash")
    }

    return decoded
  }
}
