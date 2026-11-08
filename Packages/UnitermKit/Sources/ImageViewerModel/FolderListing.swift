import Darwin
import Foundation
import SourceAccess

/// One image of a folder, as the listing saw it.
public struct ListedImage: Equatable, Sendable {
  public var name: String

  /// The modification time in seconds since the epoch.
  public var modified: Double

  public init(name: String, modified: Double) {
    self.name = name
    self.modified = modified
  }
}

/// The order a folder's images are stepped through.
public enum ImageSort: String, Codable, Sendable, Equatable {
  /// Finder's order: localized and numeric-aware, so `img2` comes before `img10`.
  case name

  /// The modification time, newest first, with ties in name order.
  case dateModified
}

public enum FolderListing {
  /// `images` in `sort` order.
  public static func sorted(_ images: [ListedImage], by sort: ImageSort) -> [ListedImage] {
    images.sorted { lhs, rhs in
      switch sort {
      case .name:
        return nameOrder(lhs.name, rhs.name) == .orderedAscending

      case .dateModified:
        if lhs.modified != rhs.modified { return lhs.modified > rhs.modified }

        return nameOrder(lhs.name, rhs.name) == .orderedAscending
      }
    }
  }

  public static func nameOrder(_ lhs: String, _ rhs: String) -> ComparisonResult {
    let order = lhs.localizedStandardCompare(rhs)

    guard order == .orderedSame else { return order }

    return lhs.compare(rhs, options: .literal)
  }

  /// The index to land on when the image named `name`, last modified at `modified`, is wanted. The
  /// image itself when it is listed. Otherwise the image that follows its place in `sort` order,
  /// or the last one when it would have come after them all.
  public static func nearest(
    toName name: String, modified: Double?, in images: [ListedImage], sort: ImageSort
  ) -> Int? {
    guard !images.isEmpty else { return nil }

    if let index = images.firstIndex(where: { $0.name == name }) { return index }

    let wanted = ListedImage(name: name, modified: modified ?? 0)

    for (index, image) in images.enumerated() where isBefore(wanted, image, sort: sort) {
      return index
    }

    return images.count - 1
  }

  private static func isBefore(_ lhs: ListedImage, _ rhs: ListedImage, sort: ImageSort) -> Bool {
    switch sort {
    case .name:
      return nameOrder(lhs.name, rhs.name) == .orderedAscending

    case .dateModified:
      if lhs.modified != rhs.modified { return lhs.modified > rhs.modified }

      return nameOrder(lhs.name, rhs.name) == .orderedAscending
    }
  }
}
