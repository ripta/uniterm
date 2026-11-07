import AppKit
import AppletKit
import ImageViewerModel
import ImageWire
import SourceAccess
import StatusKit
import Theme
import UniformTypeIdentifiers

/// Shows one image, or the first image of a folder.
///
/// Every load goes through `replaceSource`. The open panel, a drop, the router, and a restore all
/// reach the same path. It finds and opens the source off the main thread, then hands the image's
/// descriptor to the pane's helper. The app never reads image bytes: the helper decodes in its own
/// sandbox and sends pixels the app has checked.
///
/// The description holds the source's path and bookmark and the current image's name, never
/// pixels. `describe()` reads memory only.
@MainActor
public final class ImageViewerApplet: Applet, SourceReplacing {
  public let typeID = ImageViewerDescription.typeID
  public weak var host: (any AppletHost)?
  public let isRunningSomething = false

  public private(set) var title = ImageViewerApplet.untitled
  public private(set) var segments: [AppletSegment] = []
  public private(set) var publishedTabs: AppletTabList

  private static let untitled = "Image viewer"

  let content: ImageViewerView
  let client: ImageHelperClient

  private let bitmapBudget: ImageBitmapBudget
  private let lease: ImageBitmapBudget.Lease

  private var record: ImageViewerDescription
  private var describesFromRecord: Bool
  private var restoreWaitsForStart: Bool
  private var closed = false
  private var alerts = AppletAlerts()
  private var palette = ThemePalette.latte
  private var loadOrigin = LoadOrigin.user
  private var loading: Task<Void, Never>?
  private var loadGeneration = 0
  private var resizeCheck: Task<Void, Never>?

  private(set) var types = SupportedImageTypes()
  private(set) var phase = Phase.empty
  private var folder: OpenedFolder?
  private var openFile: OpenedImageFile?
  private(set) var listing: [ListedImage] = []
  private(set) var index: Int?

  /// What is on screen, and the bytes the bitmap budget holds for it.
  private(set) var info: SourceInfo?
  private(set) var shownPixels: PixelSize?
  private(set) var shownSpace: OutputSpace?
  private var shownBytes = 0

  private var plan = AnimationPlan(delays: [0])
  private var frames: [Int: Frame] = [:]
  private var currentFrame = 0
  private var waitingFor: Int?
  private var playing: Task<Void, Never>?
  private var isDetached = false

  /// Frames kept ahead of the one showing. The bitmap budget can cut it to none.
  private static let framesAhead = 2

  enum Phase: Equatable {
    case empty
    case opening
    case showing
    case problem(PaneMessage)
  }

  struct Frame {
    var image: CGImage
    var bytes: Int
  }

  /// An empty pane that starts in `startDirectory`. The directory is explicit, and the applet never
  /// reads it from another pane.
  public convenience init(startDirectory: String?) {
    self.init(
      startDirectory: startDirectory, settings: HelperSettings(location: .bundled()),
      helperBudget: .shared, bitmapBudget: .shared)
  }

  init(
    startDirectory: String?, settings: HelperSettings, helperBudget: ImageHelperBudget,
    bitmapBudget: ImageBitmapBudget
  ) {
    record = ImageViewerDescription(startDirectory: startDirectory)
    restoreWaitsForStart = false
    describesFromRecord = false

    content = ImageViewerView(frame: .zero)
    client = ImageHelperClient(settings: settings, budget: helperBudget)
    self.bitmapBudget = bitmapBudget
    lease = bitmapBudget.makeLease()
    publishedTabs = AppletTabList(first: AppletTab(id: .make(), title: Self.untitled))

    wire()
    refresh()
  }

  /// Restores a pane from its description. The source is found and opened when the pane starts, so
  /// restoring touches nothing on disk. A description this build cannot read is refused.
  public convenience init(restoring description: AppletDescription) throws {
    try self.init(
      restoring: description, settings: HelperSettings(location: .bundled()),
      helperBudget: .shared, bitmapBudget: .shared)
  }

  init(
    restoring description: AppletDescription, settings: HelperSettings,
    helperBudget: ImageHelperBudget, bitmapBudget: ImageBitmapBudget
  ) throws {
    record = try ImageViewerDescription.decode(description)
    restoreWaitsForStart = record.path != nil
    describesFromRecord = true

    content = ImageViewerView(frame: .zero)
    client = ImageHelperClient(settings: settings, budget: helperBudget)
    self.bitmapBudget = bitmapBudget
    lease = bitmapBudget.makeLease()
    publishedTabs = AppletTabList(first: AppletTab(id: .make(), title: Self.untitled))

    wire()
    refresh()
  }

  /// The factory behind the router and the launcher: a pane that starts in `startDirectory` and
  /// opens `file`.
  public static func opening(_ file: URL, startDirectory: String) throws -> ImageViewerApplet {
    let applet = ImageViewerApplet(startDirectory: startDirectory)
    try applet.replaceSource(with: file, startDirectory: startDirectory)

    return applet
  }

  public var view: NSView { content }

  public var openPanelContentTypes: [UTType]? { types.openPanelTypes }

  public var currentDirectory: String? {
    if let path = record.path {
      let folder = record.kind == .folder ? path : (path as NSString).deletingLastPathComponent

      if Self.isDirectory(folder) { return folder }
    }

    if let start = record.startDirectory, Self.isDirectory(start) { return start }

    return nil
  }

  private static func isDirectory(_ path: String) -> Bool {
    var isDirectory: ObjCBool = false

    return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
      && isDirectory.boolValue
  }

  private func wire() {
    content.onOpen = { [weak self] in self?.showOpenPanel() }
    content.onRetry = { [weak self] in self?.retry() }
    content.onDrop = { [weak self] urls in self?.handleDrop(urls) ?? false }
    content.onGeometryChange = { [weak self] in self?.geometryChanged() }
    client.onEvent = { [weak self] event in self?.handle(event) }
  }

  // MARK: Source

  /// Shows `file`, or the first image of it when it is a folder, in place of what the pane shows.
  /// A playing animation stops. Nothing here touches the disk, so a missing or unreadable source
  /// shows its message in the pane.
  public func replaceSource(with file: URL, startDirectory: String) throws {
    record = ImageViewerDescription(
      startDirectory: startDirectory, path: file.path, sort: record.sort)
    describesFromRecord = false
    restoreWaitsForStart = false

    begin(path: file.path, bookmark: nil, wanted: nil, origin: .user)
  }

  private func begin(path: String, bookmark: Data?, wanted: WantedImage?, origin: LoadOrigin) {
    loading?.cancel()
    loadGeneration += 1
    loadOrigin = origin
    alerts.replaceLoad()
    clearImage()

    folder = nil
    openFile = nil
    listing = []
    index = nil
    phase = .opening
    refresh()

    let generation = loadGeneration
    let storedKind = record.kind
    let sort = record.sort
    let supported = types

    loading = Task { [weak self] in
      let result = await SourceLoader.load(
        path: path, bookmark: bookmark, storedKind: storedKind, wanted: wanted, sort: sort,
        types: supported)

      guard let self, generation == self.loadGeneration, !self.closed else { return }

      self.loading = nil
      self.finishLoading(result)
    }
  }

  private func finishLoading(_ result: Result<LoadedSource, SourceLoadFailure>) {
    describesFromRecord = false

    switch result {
    case .failure(let failure):
      phase = .problem(
        PaneMessage(text: failure.localizedDescription, offersOpen: true, offersRetry: false))
      notify(.warning, failure.localizedDescription, delivery: .historyOnly)
      refresh()

    case .success(let loaded):
      record.bookmark = loaded.resolved.bookmark
      record.kind = loaded.kind

      if let movedFrom = loaded.resolved.movedFrom {
        record.path = movedFrom
        notify(.info, "Moved. Found at \(movedFrom).", delivery: .message)
      }

      folder = loaded.folder
      listing = loaded.listing
      index = loaded.index

      if let file = loaded.file {
        show(file: file)
      }
    }
  }

  private func show(file: OpenedImageFile) {
    openFile = file
    record.current = file.name
    record.currentModified = file.modified
    phase = .opening
    refresh()

    client.open(file)
  }

  /// Opens the shown image again, as after a helper crash.
  func retry() {
    guard let file = openFile else {
      if let path = record.path {
        begin(
          path: path, bookmark: record.bookmark,
          wanted: record.current.map { WantedImage(name: $0, modified: record.currentModified) },
          origin: .user)
      }

      return
    }

    clearImage()
    show(file: file)
  }

  /// A drop of one file or folder replaces the pane's source. Several items are refused with a
  /// warning, and so is a drop that carries no file URL. The pane keeps what it showed.
  func handleDrop(_ urls: [URL]) -> Bool {
    guard let item = urls.first else {
      notify(
        .warning,
        "Drop a file or a folder from Finder. Images dragged from other apps are not supported.",
        delivery: .message)
      return false
    }

    guard urls.count == 1 else {
      notify(
        .warning, "Drop one file or folder at a time. The image viewer shows one source in a pane.",
        delivery: .message)
      return false
    }

    do {
      try replaceSource(with: item, startDirectory: SourceStartDirectory.of(item))
      return true
    } catch {
      notify(
        .warning,
        "\u{201C}\(item.lastPathComponent)\u{201D} could not be opened: \(error.localizedDescription)",
        delivery: .message)
      return false
    }
  }

  private func showOpenPanel() {
    Task { @MainActor [weak self] in
      guard let self else { return }

      await SourceOpening.open(self, picker: SystemOpenPanel.pick)
    }
  }

  // MARK: Helper events

  private func handle(_ event: HelperEvent) {
    guard !closed else { return }

    switch event {
    case .types(let identifiers):
      types.update(helperTypes: identifiers)

    case .opened(let opened):
      info = opened
      plan = AnimationPlan(delays: opened.frameDelays)
      currentFrame = 0
      requestStill()
      refresh()

    case .image(let request, let header, let pixels):
      received(request, header, pixels)

    case .failed(let request, let kind, let text):
      failed(request, kind, text)

    case .refused(let request, let text):
      if request.kind == .still {
        problem(text, offersRetry: true)
      } else {
        stopAnimating()
      }

    case .ended(let reason, _):
      ended(reason)
    }
  }

  private var imageName: String { record.current ?? title }

  private func ended(_ reason: HelperEnd) {
    clearImage()
    stopAnimating()

    let name = "\u{201C}\(imageName)\u{201D}"
    let text: String

    switch reason {
    case .crashed:
      text = "The image decoder stopped while showing \(name). A damaged file can cause this."

    case .unresponsive:
      text = "The image decoder stopped responding while showing \(name)."

    case .overranTimeBound:
      text = "\(name) took longer to decode than uniterm allows, so it is past the limit."

    case .overFootprint:
      text =
        "\(name) needs more memory than uniterm lets an image decoder use, so it is past the limit."

    case .misbehaved:
      text = "The image decoder sent something uniterm refused while showing \(name)."

    case .versionMismatch:
      text = ImageProtocol.mismatchText

    case .unavailable(let reason):
      text = reason
    }

    problem(text, offersRetry: reason.offersRetry)
  }

  private func failed(_ request: DecodeRequest?, _ kind: FailureKind, _ text: String) {
    switch kind {
    case .staleSource:
      return

    case .noSource:
      problem(text, offersRetry: true)

    case .unsupportedFormat, .unreadable, .limit:
      if let request, request.kind == .frame {
        stopAnimating()
        return
      }

      problem(text, offersRetry: false)
    }
  }

  private func problem(_ text: String, offersRetry: Bool) {
    phase = .problem(PaneMessage(text: text, offersOpen: true, offersRetry: offersRetry))
    notify(.warning, text, delivery: .historyOnly)
    refresh()
  }

  // MARK: Decoding

  private func requestedLongerSide(for info: SourceInfo) -> Int {
    let native = PixelSize(width: Int(info.width), height: Int(info.height))
    let displayed = content.displayedPixels(for: native)

    guard displayed.longer > 0 else { return min(native.longer, 2048) }

    return FitMath.requestedLongerSide(displayed: displayed, native: native)
  }

  private func requestStill() {
    guard let info else { return }

    client.decode(maxPixel: requestedLongerSide(for: info), frame: currentFrame, kind: .still)
  }

  private func received(_ request: DecodeRequest, _ header: ImageHeader, _ pixels: Data) {
    guard let info, request.source == info.source else { return }

    let native = PixelSize(width: Int(info.width), height: Int(info.height))

    guard let image = BitmapFactory.makeImage(header, pixels: pixels) else {
      problem("The image could not be shown.", offersRetry: false)
      return
    }

    let size = PixelSize(width: Int(header.width), height: Int(header.height))

    if request.kind == .frame {
      store(frame: Int(header.frame), image: image, bytes: pixels.count)
      return
    }

    releaseShown()
    dropFrames()

    guard bitmapBudget.reserve(pixels.count, lease: lease) else {
      problem(
        "There is not enough memory to show \u{201C}\(imageName)\u{201D} right now. Close an image pane and retry.",
        offersRetry: true)
      return
    }

    shownBytes = pixels.count
    shownPixels = size
    shownSpace = header.space
    currentFrame = Int(header.frame)
    phase = .showing
    content.show(image: image, native: native, hdr: header.space.isHDR)
    frames[currentFrame] = Frame(image: image, bytes: 0)
    refresh()

    if plan.isAnimated { startAnimating() }
  }

  /// Releases the bitmap the budget holds for the image on screen, and the frames behind it.
  private func clearImage() {
    resizeCheck?.cancel()
    stopAnimating()
    dropFrames()
    releaseShown()
    shownPixels = nil
    shownSpace = nil
    info = nil
    plan = AnimationPlan(delays: [0])
    content.show(message: PaneMessage(text: "", offersOpen: false, offersRetry: false))
  }

  private func releaseShown() {
    bitmapBudget.giveBack(shownBytes, lease: lease)
    shownBytes = 0
  }

  private func dropFrames() {
    for frame in frames.values {
      bitmapBudget.giveBack(frame.bytes, lease: lease)
    }

    frames = [:]
    waitingFor = nil
  }

  // MARK: Resize

  private func geometryChanged() {
    guard phase == .showing, info != nil else { return }

    resizeCheck?.cancel()
    resizeCheck = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(120))

      guard !Task.isCancelled, let self else { return }

      self.sharpenIfNeeded()
    }
  }

  private func sharpenIfNeeded() {
    guard let info, let held = shownPixels, phase == .showing else { return }

    let native = PixelSize(width: Int(info.width), height: Int(info.height))
    let displayed = content.displayedPixels(for: native)

    if FitMath.needsSharperDecode(held: held, displayed: displayed, native: native) {
      requestStill()
    }
  }

  // MARK: Animation

  var isAnimating: Bool { playing != nil }

  /// The animation frame on screen.
  var frameIndex: Int { currentFrame }

  private func startAnimating() {
    guard plan.isAnimated, !isDetached, !closed, playing == nil else { return }

    fillWindow()
    scheduleNextFrame()
  }

  private func stopAnimating() {
    playing?.cancel()
    playing = nil
  }

  private func scheduleNextFrame() {
    playing?.cancel()

    let delay = plan.delay(of: currentFrame)

    playing = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(Int(delay)))

      guard !Task.isCancelled, let self else { return }

      self.advance()
    }
  }

  private func advance() {
    let next = plan.next(after: currentFrame)

    guard let frame = frames[next] else {
      waitingFor = next
      fillWindow()
      return
    }

    showFrame(next, frame)
  }

  private func showFrame(_ index: Int, _ frame: Frame) {
    currentFrame = index
    waitingFor = nil
    content.swap(image: frame.image)

    let keep = Set(plan.window(from: index, ahead: Self.framesAhead))

    for held in frames.keys where !keep.contains(held) {
      if let dropped = frames.removeValue(forKey: held) {
        bitmapBudget.giveBack(dropped.bytes, lease: lease)
      }
    }

    fillWindow()
    scheduleNextFrame()
  }

  /// Asks for the next frame of the window that is not held. Frame requests yield to a still.
  private func fillWindow() {
    guard let info else { return }

    for wanted in plan.window(from: currentFrame, ahead: Self.framesAhead)
    where frames[wanted] == nil {
      client.decode(maxPixel: requestedLongerSide(for: info), frame: wanted, kind: .frame)
      return
    }
  }

  private func store(frame index: Int, image: CGImage, bytes: Int) {
    guard plan.isAnimated, plan.window(from: currentFrame, ahead: Self.framesAhead).contains(index)
    else { return }

    guard bitmapBudget.reserve(bytes, lease: lease) else {
      stopAnimating()
      notify(
        .warning, "The animation paused because there is not enough memory to keep its frames.",
        delivery: .message)
      return
    }

    frames[index] = Frame(image: image, bytes: bytes)

    if waitingFor == index, let frame = frames[index], playing != nil {
      showFrame(index, frame)
    } else {
      fillWindow()
    }
  }

  // MARK: Applet

  public func start(origin: StartOrigin) {
    guard restoreWaitsForStart, let path = record.path else { return }

    restoreWaitsForStart = false
    begin(
      path: path, bookmark: record.bookmark,
      wanted: record.current.map { WantedImage(name: $0, modified: record.currentModified) },
      origin: origin.loadOrigin)
  }

  public func close() {
    closed = true
    loading?.cancel()
    resizeCheck?.cancel()
    stopAnimating()
    alerts.discard()
    clearImage()
    client.shutdown()
    bitmapBudget.release(lease)
    folder = nil
    openFile = nil
  }

  /// Pauses an animation and holds back alerts while the pane is off screen.
  public func detach() {
    isDetached = true
    alerts.detach()
    stopAnimating()
  }

  public func reattach() {
    isDetached = false
    alerts.reattach(from: self, to: host)

    if phase == .showing, plan.isAnimated { startAnimating() }
  }

  public func focus() {
    content.window?.makeFirstResponder(content)
  }

  public func apply(_ palette: ThemePalette) {
    self.palette = palette
    content.apply(palette)
  }

  public func describe() -> AppletDescription {
    (try? record.appletDescription())
      ?? AppletDescription(
        type: ImageViewerDescription.typeID, version: ImageViewerDescription.currentVersion,
        payload: .object([:]))
  }

  // MARK: Display

  private func notify(_ level: StatusLevel, _ text: String, delivery: AppletNotice.Delivery) {
    alerts.deliver(
      AppletNotice(level, text, delivery: delivery), origin: loadOrigin, from: self, to: host)
  }

  private func refresh() {
    guard !closed else { return }

    switch phase {
    case .empty:
      content.show(
        message: PaneMessage(
          text: "Open an image or a folder, or drop one here.", offersOpen: true, offersRetry: false
        ))

    case .opening:
      content.show(
        message: PaneMessage(text: "Opening\u{2026}", offersOpen: false, offersRetry: false))

    case .problem(let message):
      content.show(message: message)

    case .showing:
      break
    }

    let newTitle = record.current ?? Self.untitled
    let newSegments = segmentsForState()
    let titleChanged = newTitle != title

    guard titleChanged || newSegments != segments else { return }

    title = newTitle
    segments = newSegments

    if titleChanged {
      publishedTabs = AppletTabList(first: AppletTab(id: publishedTabs.first.id, title: newTitle))
      host?.appletTabsDidChange(self)
    }

    host?.appletDidChange(self)
  }

  private func segmentsForState() -> [AppletSegment] {
    guard phase == .showing, let info else { return [] }

    var segments = [
      AppletSegment(
        symbolName: "photo", text: "\(info.width.formatted()) \u{00D7} \(info.height.formatted())")
    ]

    if plan.isAnimated {
      segments.append(
        AppletSegment(symbolName: "play.rectangle", text: "\(plan.frameCount) frames"))
    }

    if listing.count > 1, let index {
      segments.append(
        AppletSegment(
          symbolName: "folder", text: "\((index + 1).formatted()) of \(listing.count.formatted())"))
    }

    return segments
  }
}
