import AppletKit
import Foundation
import GeoData

/// The restorable state of a map viewer.
///
/// It is inert. It holds no pin, since pins from a program are program output and stay off disk.
/// The payload carries every field the later milestones store, so adding pins from a file or from
/// programs needs no version bump. Until a source writes a field, it is absent or zero.
public struct MapViewerDescription: Codable, Equatable, Sendable {
  public static let typeID = "map-viewer"

  /// The version of the payload this build reads and writes. A change an older build cannot
  /// round-trip bumps it.
  public static let currentVersion = 1

  /// The directory the pane started in. An empty pane reports it as its current directory.
  public var startDirectory: String?

  /// The part of the globe the map shows. Absent until the map has shown one.
  public var region: GeoRegion?

  public var style: MapStyle

  /// The palette accent token the file's pins take when they name none. Absent until a file loads.
  /// A name that is not an accent token reads as the layer's first default, and is stored again
  /// when a file loads.
  public var fileAccent: String?

  /// The file's absolute path, as the user named it.
  public var path: String?

  /// A macOS bookmark of the file. It finds the file after a move or a rename.
  public var bookmark: Data?

  /// How many distinct layers of program pins held pins in this launch. It is the only trace of
  /// those layers in the layout file.
  public var commandLayerCount: Int

  public init(
    startDirectory: String? = nil, region: GeoRegion? = nil, style: MapStyle = .standard,
    fileAccent: String? = nil, path: String? = nil, bookmark: Data? = nil,
    commandLayerCount: Int = 0
  ) {
    self.startDirectory = startDirectory
    self.region = region
    self.style = style
    self.fileAccent = fileAccent
    self.path = path
    self.bookmark = bookmark
    self.commandLayerCount = commandLayerCount
  }

  private enum CodingKeys: String, CodingKey {
    case startDirectory
    case region
    case style
    case fileAccent
    case path
    case bookmark
    case commandLayerCount
  }

  /// A key absent from the stored payload takes its default, so a description written before a
  /// source filled a field still reads.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    startDirectory = try container.decodeIfPresent(String.self, forKey: .startDirectory)
    region = try container.decodeIfPresent(GeoRegion.self, forKey: .region)
    style = try container.decodeIfPresent(MapStyle.self, forKey: .style) ?? .standard
    fileAccent = try container.decodeIfPresent(String.self, forKey: .fileAccent)
    path = try container.decodeIfPresent(String.self, forKey: .path)
    bookmark = try container.decodeIfPresent(Data.self, forKey: .bookmark)
    commandLayerCount = try container.decodeIfPresent(Int.self, forKey: .commandLayerCount) ?? 0
  }

  public func appletDescription() throws -> AppletDescription {
    AppletDescription(
      type: Self.typeID, version: Self.currentVersion, payload: try JSONValue(encoding: self))
  }

  /// Reads a description. A description of another type, a newer version, or a shape that does not
  /// decode is refused, and the caller keeps the original. An unknown style is not damage and
  /// reads as the standard map.
  public static func decode(_ description: AppletDescription) throws -> MapViewerDescription {
    guard description.type == typeID else {
      throw AppletRestoreError.wrongType(expected: typeID, found: description.type)
    }

    guard description.version <= currentVersion else {
      throw AppletRestoreError.newerVersion(found: description.version, supported: currentVersion)
    }

    let decoded: MapViewerDescription
    do {
      decoded = try description.payload.decoded(as: MapViewerDescription.self)
    } catch {
      throw AppletRestoreError.corrupt("map viewer description: \(error)")
    }

    if let path = decoded.path, !path.hasPrefix("/") {
      throw AppletRestoreError.corrupt("map viewer description names a relative path")
    }

    if let start = decoded.startDirectory, !start.hasPrefix("/") {
      throw AppletRestoreError.corrupt("map viewer description starts in a relative path")
    }

    if decoded.commandLayerCount < 0 {
      throw AppletRestoreError.corrupt("map viewer description counts a negative number of layers")
    }

    return decoded
  }
}
