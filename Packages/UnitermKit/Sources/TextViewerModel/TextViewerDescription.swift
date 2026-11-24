import AppletKit
import Foundation

/// Where a viewer shows a document, in terms that survive reflow. A pixel offset lands elsewhere
/// after a width, font, or reload change, and a source anchor does not.
public struct TextViewerAnchor: Codable, Equatable, Sendable {
  /// A PDF page index, counted from zero, with a point on the page in page points.
  public var page: Int?
  public var x: Double?
  public var y: Double?

  /// The character index at the top of an RTF or Word document, in UTF-16 units.
  public var characterIndex: Int?

  /// The source line, counted from zero, where the top block of a Markdown document starts. The
  /// parser's own token map gives it.
  public var sourceLine: Int?

  /// How far down that block the top of the view is, from 0 to 1.
  public var fraction: Double?

  public init(
    page: Int? = nil, x: Double? = nil, y: Double? = nil, characterIndex: Int? = nil,
    sourceLine: Int? = nil, fraction: Double? = nil
  ) {
    self.page = page
    self.x = x
    self.y = y
    self.characterIndex = characterIndex
    self.sourceLine = sourceLine
    self.fraction = fraction
  }

  public static func pdf(page: Int, x: Double, y: Double) -> TextViewerAnchor {
    TextViewerAnchor(page: page, x: x, y: y)
  }

  public static func text(characterIndex: Int) -> TextViewerAnchor {
    TextViewerAnchor(characterIndex: characterIndex)
  }

  public static func markdown(line: Int, fraction: Double) -> TextViewerAnchor {
    TextViewerAnchor(sourceLine: line, fraction: fraction)
  }
}

/// The restorable state of a text viewer.
///
/// It is inert, and it holds nothing from the file. A restored pane reads the file again. It names
/// the file by path first and by bookmark when the path is gone.
public struct TextViewerDescription: Codable, Equatable, Sendable {
  public static let typeID = "text-viewer"

  /// The newest payload version this build reads. A change an older build cannot round-trip bumps
  /// it. The Markdown anchor's source line and fraction are optional fields of version 1, and a
  /// payload without them reads unchanged.
  ///
  /// Version 2 adds the flag that inline content was showing. An older build would drop the flag
  /// and save the payload without it, so a description that sets the flag is written as version 2,
  /// and an older build keeps it as written. Every other description stays at version 1, which
  /// every build reads.
  public static let currentVersion = 2

  /// The version of a description that sets none of the version 2 fields.
  public static let baseVersion = 1

  /// The directory the pane started in. An empty pane reports it as its current directory.
  public var startDirectory: String?

  /// The file's absolute path, as the user named it.
  public var path: String?

  /// A macOS bookmark of the file. It finds the file after a move or a rename.
  public var bookmark: Data?

  public var anchor: TextViewerAnchor?

  /// Whether the contents sidebar is shown. The field was in version 1 from the start, so the
  /// sidebar needed no version bump. A pane keeps it when it opens another file.
  public var sidebarShown: Bool

  /// True while the pane shows Markdown that a program sent. The text is never part of the
  /// description. It rides in the undo-only part, so a layout file never holds it.
  public var inlineContent: Bool

  public init(
    startDirectory: String? = nil, path: String? = nil, bookmark: Data? = nil,
    anchor: TextViewerAnchor? = nil, sidebarShown: Bool = false, inlineContent: Bool = false
  ) {
    self.startDirectory = startDirectory
    self.path = path
    self.bookmark = bookmark
    self.anchor = anchor
    self.sidebarShown = sidebarShown
    self.inlineContent = inlineContent
  }

  private enum CodingKeys: String, CodingKey {
    case startDirectory, path, bookmark, anchor, sidebarShown, inlineContent
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)

    startDirectory = try values.decodeIfPresent(String.self, forKey: .startDirectory)
    path = try values.decodeIfPresent(String.self, forKey: .path)
    bookmark = try values.decodeIfPresent(Data.self, forKey: .bookmark)
    anchor = try values.decodeIfPresent(TextViewerAnchor.self, forKey: .anchor)
    sidebarShown = try values.decodeIfPresent(Bool.self, forKey: .sidebarShown) ?? false
    inlineContent = try values.decodeIfPresent(Bool.self, forKey: .inlineContent) ?? false
  }

  public func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)

    try values.encodeIfPresent(startDirectory, forKey: .startDirectory)
    try values.encodeIfPresent(path, forKey: .path)
    try values.encodeIfPresent(bookmark, forKey: .bookmark)
    try values.encodeIfPresent(anchor, forKey: .anchor)
    try values.encode(sidebarShown, forKey: .sidebarShown)

    if inlineContent { try values.encode(true, forKey: .inlineContent) }
  }

  /// The version the description is written at: the lowest that holds all it says.
  public var writtenVersion: Int {
    inlineContent ? Self.currentVersion : Self.baseVersion
  }

  public func appletDescription(undoState: JSONValue? = nil) throws -> AppletDescription {
    AppletDescription(
      type: Self.typeID, version: writtenVersion, payload: try JSONValue(encoding: self),
      undoState: undoState.map(AppletUndoState.init))
  }

  /// Reads a description. A description of another type, a newer version, or a shape that does not
  /// decode is refused, and the caller keeps the original.
  public static func decode(_ description: AppletDescription) throws -> TextViewerDescription {
    guard description.type == typeID else {
      throw AppletRestoreError.wrongType(expected: typeID, found: description.type)
    }

    guard description.version <= currentVersion else {
      throw AppletRestoreError.newerVersion(found: description.version, supported: currentVersion)
    }

    let decoded: TextViewerDescription

    do {
      decoded = try description.payload.decoded(as: TextViewerDescription.self)
    } catch {
      throw AppletRestoreError.corrupt("text viewer description: \(error)")
    }

    if let path = decoded.path, !path.hasPrefix("/") {
      throw AppletRestoreError.corrupt("text viewer description names a relative path")
    }

    if let start = decoded.startDirectory, !start.hasPrefix("/") {
      throw AppletRestoreError.corrupt("text viewer description starts in a relative path")
    }

    if let anchor = decoded.anchor {
      if let page = anchor.page, page < 0 {
        throw AppletRestoreError.corrupt("text viewer description anchors a negative page")
      }

      if let index = anchor.characterIndex, index < 0 {
        throw AppletRestoreError.corrupt("text viewer description anchors a negative character")
      }

      if let line = anchor.sourceLine, line < 0 {
        throw AppletRestoreError.corrupt("text viewer description anchors a negative source line")
      }

      if let fraction = anchor.fraction, !fraction.isFinite {
        throw AppletRestoreError.corrupt(
          "text viewer description anchors a fraction that is not finite")
      }

      if [anchor.x, anchor.y].contains(where: { $0.map { !$0.isFinite } ?? false }) {
        throw AppletRestoreError.corrupt(
          "text viewer description anchors a point that is not finite")
      }
    }

    return decoded
  }
}
