import Foundation
import UniformTypeIdentifiers

/// What the router needs to know about content types. The app answers from the system. A test
/// answers from a table, since a made-up identifier has no conformance the system knows.
public protocol ContentTypeSystem: Sendable {
  /// The type identifier of a file or folder the router has already found to be a regular file or
  /// a directory. Nil when the system has no answer.
  func identifier(of url: URL) -> String?

  /// True when `identifier` is `other` or conforms to it.
  func conforms(_ identifier: String, to other: String) -> Bool

  /// True when the system itself declares the type.
  func isKnown(_ identifier: String) -> Bool
}

/// Answers from the system's type database. A file's type never comes from uniterm's `Info.plist`,
/// since another app may export a type uniterm imports, with a different conformance.
public struct SystemContentTypes: ContentTypeSystem {
  public init() {}

  public func identifier(of url: URL) -> String? {
    let values = try? url.resourceValues(forKeys: [.contentTypeKey])
    return values?.contentType?.identifier
  }

  public func conforms(_ identifier: String, to other: String) -> Bool {
    guard let type = UTType(identifier), let parent = UTType(other) else {
      return identifier == other
    }

    return type.conforms(to: parent)
  }

  public func isKnown(_ identifier: String) -> Bool {
    UTType(identifier) != nil
  }
}
