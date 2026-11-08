import XCTest

@testable import ImageViewerModel

final class ImageListingTests: XCTestCase {
  private func images(_ names: String...) -> [ListedImage] {
    names.enumerated().map { ListedImage(name: $1, modified: Double($0)) }
  }

  private func partial(_ batches: [[ListedImage]], selecting: Int = 0, sort: ImageSort = .name)
    -> ImageListing
  {
    var listing = ImageListing(sort: sort)

    for batch in batches { listing.append(batch) }

    listing.select(selecting)

    return listing
  }

  /// Catches a partial listing that reorders what the user already stepped through. Each batch is
  /// ordered inside itself and joins the end, so the images listed so far never move.
  func testAPartialListingKeepsAStableOrderWhileBatchesArrive() {
    var listing = ImageListing(sort: .name)

    listing.append(images("img2.png", "img10.png"))
    let before = listing.images.map(\.name)

    listing.append(images("img1.png", "img3.png"))

    XCTAssertEqual(before, ["img2.png", "img10.png"])
    XCTAssertEqual(
      listing.images.map(\.name), ["img2.png", "img10.png", "img1.png", "img3.png"])
    XCTAssertFalse(listing.isComplete)
  }

  /// Catches a finished scan that leaves the order provisional or loses the selection. The ending
  /// puts the whole listing in Finder order, and the selection follows its image.
  func testFinishingSortsTheListingAndTheSelectionFollowsItsImage() {
    var listing = partial([images("img2.png", "img10.png"), images("img1.png")], selecting: 1)

    XCTAssertEqual(listing.current?.name, "img10.png")

    listing.finish()

    XCTAssertTrue(listing.isComplete)
    XCTAssertEqual(listing.images.map(\.name), ["img1.png", "img2.png", "img10.png"])
    XCTAssertEqual(listing.current?.name, "img10.png")
    XCTAssertEqual(listing.index, 2)
  }

  /// Catches an image that is listed twice. The pane seeds the listing with the image it shows, and
  /// the scan reports the same file later.
  func testASeededImageIsNotListedAgainByTheScan() {
    var listing = ImageListing(sort: .name)

    listing.seed(ListedImage(name: "c.png", modified: 0))
    listing.append(images("a.png", "c.png", "b.png"))

    XCTAssertEqual(listing.images.map(\.name), ["c.png", "a.png", "b.png"])
    XCTAssertEqual(listing.current?.name, "c.png")
  }

  /// Catches stepping that runs off either end. Manual steps stop at the first and last image.
  func testManualSteppingStopsAtTheEnds() {
    let listing = partial([images("a.png", "b.png", "c.png")], selecting: 0)

    XCTAssertNil(listing.target(for: .previous))
    XCTAssertNil(listing.target(for: .first))
    XCTAssertEqual(listing.target(for: .next), 1)
    XCTAssertEqual(listing.target(for: .last), 2)

    var end = listing
    end.select(2)

    XCTAssertNil(end.target(for: .next))
    XCTAssertNil(end.target(for: .last))
    XCTAssertEqual(end.target(for: .first), 0)
  }

  /// Catches a slideshow that wraps while the scan still runs. At the end of a partial listing it
  /// waits. Once the listing is complete it wraps to the first image.
  func testTheSlideshowWrapsOnlyAfterTheListingEnds() {
    var listing = partial([images("a.png", "b.png")], selecting: 1)

    XCTAssertNil(listing.slideshowTarget, "a partial listing never wraps")

    listing.append(images("c.png"))
    XCTAssertEqual(listing.slideshowTarget, 2, "new images extend the show")

    listing.select(2)
    listing.finish()

    XCTAssertEqual(listing.slideshowTarget, 0)
  }

  /// Catches a slideshow that has nowhere to go and moves anyway. One image has no next.
  func testAListingOfOneImageHasNoSlideshowTarget() {
    var listing = partial([images("a.png")])

    listing.finish()

    XCTAssertNil(listing.slideshowTarget)
  }

  /// Catches a deleted image that stays in the order, or that leaves the selection on nothing. The
  /// next image in the direction of travel is selected, and the end reports that nothing is left.
  func testRemovingADeletedImageSelectsTheNextOneInTheDirectionOfTravel() {
    var listing = partial([images("a.png", "b.png", "c.png")], selecting: 1)
    listing.finish()

    XCTAssertTrue(listing.remove(named: "b.png", forward: true, wrapping: false))
    XCTAssertEqual(listing.current?.name, "c.png")

    listing.select(0)
    XCTAssertTrue(listing.remove(named: "a.png", forward: false, wrapping: true))
    XCTAssertEqual(
      listing.current?.name, "c.png", "wrapping backward from the first lands on the last")

    XCTAssertFalse(listing.remove(named: "c.png", forward: true, wrapping: false))
    XCTAssertNil(listing.index)
    XCTAssertEqual(listing.count, 0)
  }

  /// Catches a reload that moves the user off their image. It keeps the image when it is still
  /// listed, and lands on the one that follows its place when it is gone.
  func testReloadKeepsTheCurrentImageOrLandsNearestIt() {
    let scanned = images("a.png", "c.png", "d.png")

    let kept = ImageListing.reloaded(from: scanned, keeping: "c.png", modified: nil, sort: .name)
    XCTAssertTrue(kept.kept)
    XCTAssertEqual(kept.listing.current?.name, "c.png")

    let gone = ImageListing.reloaded(from: scanned, keeping: "b.png", modified: nil, sort: .name)
    XCTAssertFalse(gone.kept)
    XCTAssertEqual(gone.listing.current?.name, "c.png")

    let last = ImageListing.reloaded(from: scanned, keeping: "z.png", modified: nil, sort: .name)
    XCTAssertEqual(last.listing.current?.name, "d.png")
  }

  /// Catches a date order that lands a deleted image in the wrong place. The stored modification
  /// time places it, since the name alone could not.
  func testReloadInDateOrderLandsByTheStoredModificationTime() {
    let scanned = [
      ListedImage(name: "x", modified: 300), ListedImage(name: "y", modified: 200),
      ListedImage(name: "z", modified: 100),
    ]

    let outcome = ImageListing.reloaded(
      from: scanned, keeping: "gone", modified: 250, sort: .dateModified)

    XCTAssertEqual(outcome.listing.current?.name, "y")
  }

  /// Catches a re-sort that moves the user. The selection follows its image to the new order, and a
  /// partial listing only remembers the order for the end of the scan.
  func testResortingKeepsTheSelectedImage() {
    var listing = ImageListing(
      complete: [
        ListedImage(name: "a", modified: 1), ListedImage(name: "b", modified: 3),
        ListedImage(name: "c", modified: 2),
      ], index: 0, sort: .name)

    listing.resort(by: .dateModified)

    XCTAssertEqual(listing.images.map(\.name), ["b", "c", "a"])
    XCTAssertEqual(listing.current?.name, "a")

    var scanning = partial([images("b.png", "a.png")], selecting: 0)
    scanning.resort(by: .dateModified)

    XCTAssertEqual(scanning.images.map(\.name), ["a.png", "b.png"], "no reorder mid-scan")
    XCTAssertEqual(scanning.sort, .dateModified)
  }
}
