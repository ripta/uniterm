import Foundation

extension FolderListing {
  /// `images` in `sort` order, sorted off the calling thread. Ordering a large folder with Finder's
  /// comparison takes long enough to be seen on the main thread.
  @concurrent
  public static func sortedOffMain(_ images: [ListedImage], by sort: ImageSort) async
    -> [ListedImage]
  {
    sorted(images, by: sort)
  }
}
