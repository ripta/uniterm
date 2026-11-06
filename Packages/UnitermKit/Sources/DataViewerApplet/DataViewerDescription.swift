import AppletKit
import Foundation
import TableData

/// The restorable state of a data viewer.
///
/// It is inert, and it holds no data from the file. A restored pane reads the file again. It names
/// the file by path first and by bookmark when the path is gone. Both are stored, so a file that
/// moved is found. The sort and filter come back once the file has loaded.
public struct DataViewerDescription: Codable, Equatable, Sendable {
  public static let typeID = "data-viewer"

  /// The version of the payload this build reads and writes. A change an older build cannot
  /// round-trip bumps it.
  public static let currentVersion = 1

  /// The directory the pane started in. An empty pane reports it as its current directory.
  public var startDirectory: String?

  /// The file's absolute path, as the user named it.
  public var path: String?

  /// A macOS bookmark of the file. It finds the file after a move or a rename.
  public var bookmark: Data?

  /// The selected sheet of a workbook. Present from the first version, so a spreadsheet reader
  /// needs no version bump.
  public var sheet: String?

  public var sort: SortSpec?

  /// The filter text. Absent when there is no filter.
  public var filter: String?

  public init(
    startDirectory: String? = nil, path: String? = nil, bookmark: Data? = nil, sheet: String? = nil,
    sort: SortSpec? = nil, filter: String? = nil
  ) {
    self.startDirectory = startDirectory
    self.path = path
    self.bookmark = bookmark
    self.sheet = sheet
    self.sort = sort
    self.filter = filter
  }

  /// The sort and filter as a query.
  public var query: TableQuery {
    TableQuery(sort: sort, filter: filter ?? "")
  }

  public func appletDescription() throws -> AppletDescription {
    AppletDescription(
      type: Self.typeID, version: Self.currentVersion, payload: try JSONValue(encoding: self))
  }

  /// Reads a description. A description of another type, a newer version, or a shape that does not
  /// decode is refused, and the caller keeps the original.
  public static func decode(_ description: AppletDescription) throws -> DataViewerDescription {
    guard description.type == typeID else {
      throw AppletRestoreError.wrongType(expected: typeID, found: description.type)
    }

    guard description.version <= currentVersion else {
      throw AppletRestoreError.newerVersion(found: description.version, supported: currentVersion)
    }

    let decoded: DataViewerDescription
    do {
      decoded = try description.payload.decoded(as: DataViewerDescription.self)
    } catch {
      throw AppletRestoreError.corrupt("data viewer description: \(error)")
    }

    if let path = decoded.path, !path.hasPrefix("/") {
      throw AppletRestoreError.corrupt("data viewer description names a relative path")
    }

    if let start = decoded.startDirectory, !start.hasPrefix("/") {
      throw AppletRestoreError.corrupt("data viewer description starts in a relative path")
    }

    if let sort = decoded.sort, sort.column.occurrence < 0 {
      throw AppletRestoreError.corrupt("data viewer description sorts a column with no place")
    }

    return decoded
  }
}
