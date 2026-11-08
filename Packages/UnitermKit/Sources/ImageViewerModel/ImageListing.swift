import Foundation

/// A way to move through a folder's images.
public enum ListingStep: Sendable, Equatable {
  case next
  case previous
  case first
  case last

  /// True when the step moves toward the end of the order.
  public var isForward: Bool {
    switch self {
    case .next, .last: return true
    case .previous, .first: return false
    }
  }
}

/// The images of a folder and the one selected, from the first batch of a scan to its end.
///
/// While the scan runs, images join the end in the order they arrive, and a batch is ordered within
/// itself. An image already listed never moves, so stepping through a partial listing is stable.
/// When the scan ends, the whole listing is put in the chosen order and the selection follows its
/// image to the new place. The index and the count are provisional until then.
public struct ImageListing: Sendable, Equatable {
  public private(set) var images: [ListedImage]
  public private(set) var index: Int?
  public private(set) var isComplete: Bool
  public private(set) var sort: ImageSort

  private var seen: Set<String>
  private var removals = 0

  /// An empty listing that a scan will fill.
  public init(sort: ImageSort) {
    images = []
    index = nil
    isComplete = false
    self.sort = sort
    seen = []
  }

  /// A finished listing of `images`, which are already in `sort` order.
  public init(complete images: [ListedImage], index: Int?, sort: ImageSort) {
    self.images = images
    self.index = index
    isComplete = true
    self.sort = sort
    seen = Set(images.map(\.name))
  }

  public var count: Int { images.count }

  public var current: ListedImage? {
    guard let index, images.indices.contains(index) else { return nil }

    return images[index]
  }

  public func position(ofName name: String) -> Int? {
    images.firstIndex { $0.name == name }
  }

  /// Adds the image the pane is already showing, and selects it. The scan will not add it again.
  public mutating func seed(_ image: ListedImage) {
    guard !seen.contains(image.name) else {
      index = position(ofName: image.name)
      return
    }

    seen.insert(image.name)
    images.append(image)
    index = images.count - 1
  }

  /// Adds the images of one scan batch that are not listed yet, in `sort` order within the batch.
  public mutating func append(_ batch: [ListedImage]) {
    let fresh = batch.filter { !seen.contains($0.name) }

    for image in FolderListing.sorted(fresh, by: sort) {
      seen.insert(image.name)
      images.append(image)
    }
  }

  /// Ends the scan. The listing takes the chosen order, and the selection follows its image. When
  /// the scan already ordered the images in `ordered`, off the main thread, the listing takes that
  /// order and sorts nothing here.
  public mutating func finish(ordered: [ListedImage]? = nil) {
    isComplete = true

    if let ordered {
      apply(ordered: ordered)
      return
    }

    let selected = current?.name

    images = FolderListing.sorted(images, by: sort)
    index = selected.flatMap { position(ofName: $0) }
  }

  /// Takes the order of `ordered`, which holds the same images sorted by `sort` somewhere else. An
  /// image removed since then stays out, and one that `ordered` lacks follows the rest. The
  /// selection follows its image. A listing with no removals and the same count adopts `ordered`
  /// whole, which costs no pass over the names.
  public mutating func apply(ordered: [ListedImage]) {
    let selected = current?.name

    if removals == 0, ordered.count == images.count {
      images = ordered
    } else {
      let present = Set(images.map(\.name))
      var result = ordered.filter { present.contains($0.name) }
      let have = Set(result.map(\.name))
      let extras = images.filter { !have.contains($0.name) }

      result.append(contentsOf: FolderListing.sorted(extras, by: sort))
      images = result
    }

    index = selected.flatMap { position(ofName: $0) }
  }

  /// Records a new order without moving anything. `apply(ordered:)` follows when the images have
  /// been sorted.
  public mutating func noteSort(_ newSort: ImageSort) {
    sort = newSort
  }

  /// Changes the order. A listing still being scanned only remembers it for `finish`.
  public mutating func resort(by newSort: ImageSort) {
    sort = newSort

    guard isComplete else { return }

    let selected = current?.name

    images = FolderListing.sorted(images, by: newSort)
    index = selected.flatMap { position(ofName: $0) }
  }

  @discardableResult
  public mutating func select(_ position: Int) -> Bool {
    guard images.indices.contains(position) else { return false }

    index = position

    return true
  }

  @discardableResult
  public mutating func select(name: String) -> Bool {
    guard let found = position(ofName: name) else { return false }

    index = found

    return true
  }

  /// Where `step` goes from the selection, or nil when there is nowhere to go. Manual stepping
  /// stops at the first and last image.
  public func target(for step: ListingStep) -> Int? {
    guard !images.isEmpty else { return nil }

    switch step {
    case .next:
      guard let index else { return 0 }

      return index + 1 < images.count ? index + 1 : nil

    case .previous:
      guard let index else { return nil }

      return index > 0 ? index - 1 : nil

    case .first:
      return index == 0 ? nil : 0

    case .last:
      return index == images.count - 1 ? nil : images.count - 1
    }
  }

  /// Where the slideshow goes next. It wraps to the first image only once the scan has ended, so a
  /// partial listing never wraps early. A listing of one image has nowhere to go.
  public var slideshowTarget: Int? {
    guard !images.isEmpty else { return nil }

    guard let index else { return 0 }

    if index + 1 < images.count { return index + 1 }

    return isComplete && images.count > 1 ? 0 : nil
  }

  /// Drops the image named `name`, which is gone from the disk, and selects the one to try next in
  /// the direction of travel. Returns false when no image is left to try in that direction. The
  /// selection is cleared then, and the caller selects what the pane shows.
  @discardableResult
  public mutating func remove(named name: String, forward: Bool, wrapping: Bool) -> Bool {
    guard let at = position(ofName: name) else { return index != nil }

    images.remove(at: at)
    removals += 1

    guard !images.isEmpty else {
      index = nil
      return false
    }

    if forward {
      if at < images.count {
        index = at
      } else if wrapping {
        index = 0
      } else {
        index = nil
        return false
      }
    } else {
      if at > 0 {
        index = at - 1
      } else if wrapping {
        index = images.count - 1
      } else {
        index = nil
        return false
      }
    }

    return true
  }

  /// The listing a reload makes from a fresh, complete scan. It keeps `name` when it is still
  /// there. Otherwise it selects the image nearest where `name` stood, and `kept` is false.
  public static func reloaded(
    from scanned: [ListedImage], keeping name: String?, modified: Double?, sort: ImageSort,
    isOrdered: Bool = false
  ) -> (listing: ImageListing, kept: Bool) {
    let ordered = isOrdered ? scanned : FolderListing.sorted(scanned, by: sort)

    guard let name else {
      return (ImageListing(complete: ordered, index: ordered.isEmpty ? nil : 0, sort: sort), false)
    }

    if let at = ordered.firstIndex(where: { $0.name == name }) {
      return (ImageListing(complete: ordered, index: at, sort: sort), true)
    }

    let nearest = FolderListing.nearest(toName: name, modified: modified, in: ordered, sort: sort)

    return (ImageListing(complete: ordered, index: nearest, sort: sort), false)
  }
}

public enum SlideshowPolicy {
  /// How long the slideshow shows an image. It is fixed, with no setting.
  public static let interval: Duration = .seconds(5)
}
