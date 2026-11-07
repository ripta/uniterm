import Foundation
import UniformTypeIdentifiers

/// Which files the viewer treats as images. The app judges a file by its extension and its content
/// type only, and never reads its bytes.
///
/// Before a helper answers, any type that conforms to `public.image` counts. Once the helper lists
/// the types ImageIO decodes, the list narrows the choice. Whatever the helper lists is filtered
/// by conformance to `public.image` again, so a type such as PDF that ImageIO also reads stays
/// unopened.
public struct SupportedImageTypes: Sendable, Equatable {
  /// The helper's image types, or nil before it has answered.
  public private(set) var listed: [UTType]?

  public init(helperTypes: [String]? = nil) {
    listed = helperTypes.map { Self.imageTypes(from: $0) }
  }

  /// The identifiers in `identifiers` that name a type conforming to `public.image`.
  public static func imageIdentifiers(from identifiers: [String]) -> [String] {
    imageTypes(from: identifiers).map(\.identifier)
  }

  private static func imageTypes(from identifiers: [String]) -> [UTType] {
    identifiers.compactMap { UTType($0) }.filter { $0.conforms(to: .image) }
  }

  /// True when a file with this name is an image the viewer opens.
  public func supports(fileName: String) -> Bool {
    let ext = (fileName as NSString).pathExtension

    guard !ext.isEmpty, let type = UTType(filenameExtension: ext), type.conforms(to: .image) else {
      return false
    }

    guard let listed else { return true }

    return listed.contains { type.conforms(to: $0) }
  }

  /// The types the open panel accepts, with folders handled by the panel itself.
  public var openPanelTypes: [UTType] {
    listed ?? [.image]
  }

  /// Replaces the list with what the helper reported.
  public mutating func update(helperTypes: [String]) {
    listed = Self.imageTypes(from: helperTypes)
  }
}
