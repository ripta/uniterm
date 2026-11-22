import AppletKit
import Foundation

/// The restorable state of a Questions pane. It holds nothing.
///
/// A form is never saved. It belongs to a program that is waiting for its answer, and a restored
/// pane has no such program. The description only says that a Questions pane was here, so the
/// layout keeps its place.
public struct QuestionsDescription: Codable, Equatable, Sendable {
  public static let typeID = "questions"

  /// The version of the payload this build reads and writes.
  public static let currentVersion = 1

  public init() {}

  public func appletDescription() throws -> AppletDescription {
    AppletDescription(
      type: Self.typeID, version: Self.currentVersion, payload: try JSONValue(encoding: self))
  }

  /// Reads a description. A description of another type, a newer version, or a shape that does
  /// not decode is refused, and the caller keeps the original.
  public static func decode(_ description: AppletDescription) throws -> QuestionsDescription {
    guard description.type == typeID else {
      throw AppletRestoreError.wrongType(expected: typeID, found: description.type)
    }

    guard description.version <= currentVersion else {
      throw AppletRestoreError.newerVersion(found: description.version, supported: currentVersion)
    }

    do {
      return try description.payload.decoded(as: QuestionsDescription.self)
    } catch {
      throw AppletRestoreError.corrupt("Questions description: \(error)")
    }
  }
}
