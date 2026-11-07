import AppKit
import AppletKit
import ImageViewerModel
import ImageWire
import SourceAccess

/// Stepping through a folder: the scan, the selection, and the load that follows it.
///
/// The selection is the listing's index. It moves at once on every step, so a held key keeps
/// advancing. The load follows one image at a time: when one finishes, the pane loads whatever is
/// selected then. A held key through large images therefore shows each image as it arrives, and the
/// helper decodes one at a time without ever being respawned.
extension ImageViewerApplet {
  // MARK: Scan

  /// Lists the folder in the background. The first batch of a fresh folder selects its first image.
  /// A reload gathers the whole scan before it replaces the listing.
  func startScan(reload: Bool = false) {
    guard let folder else { return }

    scanTask?.cancel()
    scanGeneration += 1
    reloadBuffer = reload ? [] : nil

    let generation = scanGeneration
    let stream = FolderScan.updates(
      of: folder, supporting: types, sort: listing.sort, pace: scanPace)

    scanTask = Task { [weak self] in
      for await update in stream {
        guard let self, generation == self.scanGeneration, !self.closed else { return }

        self.apply(update)
      }
    }
  }

  private func apply(_ update: ScanUpdate) {
    switch update {
    case .batch(let batch):
      if reloadBuffer != nil {
        reloadBuffer?.append(contentsOf: batch)
        return
      }

      listing.append(batch)

      if landing == nil, listing.index == nil, committedName == nil, loadingName == nil,
        listing.count > 0
      {
        listing.select(0)
        pump()
      }

      refresh()

    case .ordered(let sort, let images):
      scannedOrder = (sort, images)

    case .finished:
      let ordered = scannedOrder.flatMap { $0.sort == listing.sort ? $0.images : nil }

      scannedOrder = nil

      if let scanned = reloadBuffer {
        reloadBuffer = nil
        applyReload(scanned, ordered: ordered)
        return
      }

      finishScan(ordered: ordered)

    case .failed(let error):
      if reloadBuffer != nil {
        reloadBuffer = nil
        notify(
          .warning, "The folder could not be listed again: \(error.localizedDescription)",
          delivery: .message)
        return
      }

      scanFailed(error)
    }
  }

  private func finishScan(ordered: [ListedImage]?) {
    listing.finish(ordered: ordered)

    if let wanted = landing {
      landing = nil
      land(on: wanted)
    } else if listing.count == 0 {
      showNoImages()
    }

    refresh()
    maybePrefetch()
  }

  private func scanFailed(_ error: SourceAccessError) {
    if listing.count == 0 {
      landing = nil
      phase = .problem(
        PaneMessage(
          text: error.localizedDescription, offersOpen: true,
          offersRetry: false))
      refresh()
      return
    }

    folderNotListed = true
    listing.finish()
    postNotListedNotice()
    refresh()
  }

  private func showNoImages() {
    let path = folder?.path ?? record.path ?? ""
    let text = SourceLoadFailure.noImages(folder: path).localizedDescription

    phase = .problem(PaneMessage(text: text, offersOpen: true, offersRetry: false))
    notify(.warning, text, delivery: .historyOnly)
  }

  /// Selects the image nearest `wanted` once the scan has ended and loads it.
  private func land(on wanted: WantedImage) {
    guard
      let at = FolderListing.nearest(
        toName: wanted.name, modified: wanted.modified, in: listing.images, sort: listing.sort)
    else {
      showNoImages()
      return
    }

    listing.select(at)
    pump()
  }

  private func applyReload(_ scanned: [ListedImage], ordered: [ListedImage]?) {
    guard !scanned.isEmpty else {
      notify(.warning, "The folder has no images in it now.", delivery: .message)
      return
    }

    let outcome = ImageListing.reloaded(
      from: ordered ?? scanned, keeping: committedName ?? record.current,
      modified: record.currentModified,
      sort: listing.sort, isOrdered: ordered != nil)

    listing = outcome.listing
    prefetchFailed = []
    dropPrefetched()

    notify(
      .info, "Reloaded. \(listing.count.formatted()) \(listing.count == 1 ? "image" : "images").",
      delivery: .message)

    if !outcome.kept { pump() }

    refresh()
    maybePrefetch()
  }

  func cancelNavigation() {
    navTask?.cancel()
    navTask = nil
    navGeneration += 1

    scanTask?.cancel()
    scanTask = nil
    scanGeneration += 1
    reloadBuffer = nil

    prefetchTask?.cancel()
    prefetchTask = nil
  }

  // MARK: Stepping

  func canStep(_ step: ListingStep) -> Bool {
    listing.target(for: step) != nil
  }

  /// A step the user made. It stops the slideshow, whether or not there is an image to go to.
  func step(_ step: ListingStep) {
    stopSlideshow()

    guard let target = listing.target(for: step) else { return }

    travelsForward = step.isForward
    listing.select(target)
    refresh()
    pump()
  }

  func handle(key: ImageKey) -> Bool {
    guard listing.count > 0 else { return false }

    switch key {
    case .right:
      if isZoomedPastFit { return panImage(by: key) }
      step(.next)

    case .left:
      if isZoomedPastFit { return panImage(by: key) }
      step(.previous)

    case .up, .down:
      return panImage(by: key)

    case .home:
      step(.first)

    case .end:
      step(.last)

    case .space:
      step(.next)

    case .shiftSpace:
      step(.previous)
    }

    return true
  }

  /// Loads the selection when the pane is not busy loading another image.
  func pump() {
    guard !closed, loadingName == nil, let target = listing.current,
      target.name != committedName
    else { return }

    beginLoad(of: target, bypassCache: false)
  }

  /// Starts showing `image`. A decode the pane already holds for it is used as it is. A decode in
  /// flight for it becomes the shown image when it arrives. Otherwise the file is opened off the
  /// main thread and handed to the helper.
  func beginLoad(of image: ListedImage, bypassCache: Bool) {
    exitZoom()
    navGeneration += 1
    navTask?.cancel()
    navTask = nil

    let generation = navGeneration

    if !bypassCache {
      if let entry = cache.take(name: image.name, modified: image.modified) {
        if client.select(source: entry.value.info.source) {
          display(entry)
          return
        }

        bitmapBudget.giveBack(entry.value.bytes, lease: lease)
      }

      if var job = prefetch, job.name == image.name, job.modified == image.modified {
        job.promoted = true
        prefetch = job
        loadingName = image.name
        record.current = image.name
        record.currentModified = image.modified
        refresh()
        return
      }
    }

    cancelPrefetchOpening()

    loadingName = image.name
    record.current = image.name
    record.currentModified = image.modified
    refresh()

    guard let folder else {
      if let file = openFile { show(file: file) }
      return
    }

    navTask = Task { [weak self] in
      let result = await SourceLoader.openImage(in: folder, named: image.name)

      guard let self, generation == self.navGeneration, !self.closed else { return }

      self.navTask = nil

      switch result {
      case .success(let file): self.show(file: file)
      case .failure: self.targetVanished(image)
      }
    }
  }

  /// Shows a decode the pane already holds. The image on screen becomes the previous one.
  func display(_ entry: FitCache<Shot>.Entry) {
    let next = entry.value

    navTask?.cancel()
    navTask = nil
    stopAnimating()
    dropFrames()
    retireShown(keeping: next.name)

    shot = next
    info = next.info
    sourceName = next.name
    sourceModified = next.modified
    record.current = next.name
    record.currentModified = next.modified
    plan = AnimationPlan(delays: next.info.frameDelays)
    currentFrame = 0
    committedName = next.name
    loadingName = nil
    phase = .showing

    content.show(
      image: next.image,
      native: PixelSize(width: Int(next.info.width), height: Int(next.info.height)),
      actualScale: next.info.actualScale, hdr: next.space.isHDR, zoomable: !plan.isAnimated)
    frames[0] = Frame(image: next.image, bytes: 0)
    refresh()

    if plan.isAnimated { startAnimating() }

    shownSettled()
  }

  /// A file was deleted since the scan. It is skipped with a warning, and the pane goes on to the
  /// next image in the direction of travel. When no image is left to try, the selection returns to
  /// the image on screen, and a playing slideshow stops with the reason.
  private func targetVanished(_ image: ListedImage) {
    notify(
      .warning, "\u{201C}\(image.name)\u{201D} is no longer in the folder, so it was skipped.",
      delivery: .message)

    loadingName = nil

    let more = listing.remove(
      named: image.name, forward: travelsForward, wrapping: isPlaying && listing.isComplete)

    if more, let next = listing.current, next.name != committedName {
      beginLoad(of: next, bypassCache: false)
      return
    }

    if let committedName { listing.select(name: committedName) }

    if let committedName, let held = shot, held.name == committedName {
      record.current = held.name
      record.currentModified = held.modified
    }

    if isPlaying && listing.isComplete {
      stopSlideshow()
      notify(
        .warning, "The slideshow stopped because the rest of the images were deleted.",
        delivery: .message)
    }

    refresh()
  }

  /// What follows an image finishing: a selection that moved on while it loaded, then the prefetch.
  func shownSettled() {
    pump()
    maybePrefetch()
    geometryChanged()
  }

  // MARK: Commands

  func setSort(_ sort: ImageSort) {
    guard sort != record.sort else { return }

    record.sort = sort
    sortGeneration += 1
    listing.noteSort(sort)
    dropPrefetched()
    refresh()
    host?.appletDidChange(self)

    guard listing.isComplete else { return }

    let images = listing.images
    let generation = sortGeneration

    Task { [weak self] in
      let ordered = await FolderListing.sortedOffMain(images, by: sort)

      guard let self, generation == self.sortGeneration, !self.closed else { return }

      self.listing.apply(ordered: ordered)
      self.refresh()
      self.maybePrefetch()
    }
  }

  /// Lists the folder again. The current image stays, or the pane lands on the one nearest it.
  func reloadFolder() {
    guard let path = record.path, phase != .empty else { return }

    if folder == nil || folderNotListed {
      begin(
        path: path, bookmark: record.bookmark,
        wanted: record.current.map { WantedImage(name: $0, modified: record.currentModified) },
        origin: .user)
      return
    }

    startScan(reload: true)
  }

  var hasSource: Bool { record.path != nil && phase != .empty }
}
