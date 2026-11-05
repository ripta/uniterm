import AppKit
import AppletKit
import StatusKit
import TableData
import Theme

/// Shows one file as a table, with a sort and a filter.
///
/// Every load goes through `replaceSource`. The open panel, a drop, the router, and a restore all
/// reach the same path, which finds the file off the main thread and hands it to the session. The
/// session reads it, also off the main thread, and the applet shows what it holds.
///
/// The description holds the file's path and bookmark, never its rows. `describe()` reads memory
/// only.
@MainActor
public final class DataViewerApplet: Applet, SourceReplacing {
  public let typeID = DataViewerDescription.typeID
  public weak var host: (any AppletHost)?
  public let isRunningSomething = false

  public private(set) var title = DataViewerApplet.untitled
  public private(set) var segments: [AppletSegment] = []
  public private(set) var publishedTabs: AppletTabList

  private static let untitled = "Data viewer"

  let content: DataViewerView
  let session: TableSession
  private var record: DataViewerDescription
  private var opening: Task<Void, Never>?
  private var openGeneration = 0
  private var resolvedNotice: String?
  private var restoreWaitsForStart: Bool
  private var describesFromRecord: Bool
  private var closed = false
  private let budget: TableBudget
  private let pageTarget: Int
  private var nested: NestedTable?
  private var palette = ThemePalette.latte

  /// An empty pane that starts in `startDirectory`. The directory is explicit, and the applet never
  /// reads it from another pane.
  public init(
    startDirectory: String?, budget: TableBudget = .shared,
    pageTarget: Int = TableLoader.defaultPageTarget
  ) {
    record = DataViewerDescription(startDirectory: startDirectory)
    restoreWaitsForStart = false
    describesFromRecord = false
    self.budget = budget
    self.pageTarget = pageTarget

    session = TableSession(budget: budget, pageTarget: pageTarget)
    content = DataViewerView(session: session)
    publishedTabs = AppletTabList(first: AppletTab(id: .make(), title: Self.untitled))

    wire()
  }

  /// Restores a pane from its description. The file is found and read when the pane starts, so
  /// restoring touches nothing on disk. A description this build cannot read is refused.
  public init(
    restoring description: AppletDescription, budget: TableBudget = .shared,
    pageTarget: Int = TableLoader.defaultPageTarget
  ) throws {
    record = try DataViewerDescription.decode(description)
    restoreWaitsForStart = record.path != nil
    describesFromRecord = true
    self.budget = budget
    self.pageTarget = pageTarget

    session = TableSession(budget: budget, pageTarget: pageTarget)
    content = DataViewerView(session: session)
    publishedTabs = AppletTabList(first: AppletTab(id: .make(), title: Self.untitled))

    wire()
    refresh()
  }

  /// The factory behind the router and the launcher: a pane that starts in `startDirectory` and
  /// opens `file`.
  public static func opening(
    _ file: URL, startDirectory: String, budget: TableBudget = .shared
  ) throws -> DataViewerApplet {
    let applet = DataViewerApplet(startDirectory: startDirectory, budget: budget)
    try applet.replaceSource(with: file, startDirectory: startDirectory)

    return applet
  }

  public var view: NSView { content }

  public var currentDirectory: String? {
    if let path = record.path {
      let folder = (path as NSString).deletingLastPathComponent

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
    session.onChange = { [weak self] in self?.refresh() }
    content.onSort = { [weak self] column in self?.session.cycleSort(column) }
    content.onFilter = { [weak self] text in self?.session.setFilter(text) }
    content.onOpen = { [weak self] in self?.showOpenPanel() }
    content.onDrop = { [weak self] urls in self?.handleDrop(urls) ?? false }
    content.onExpand = { [weak self] request in self?.expand(request) }
  }

  // MARK: Nested

  /// Opens a nested cell as a table in a popover over the cell, within this pane.
  private func expand(_ request: NestedRequest) {
    nested?.close()

    let table = NestedTable(
      bytes: request.bytes, title: request.title, budget: budget, palette: palette,
      pageTarget: pageTarget)

    nested = table
    table.present(relativeTo: request.rect, of: request.anchor)
  }

  // MARK: Source

  /// Shows `file` in place of what the pane shows. The load before it stops, and the new file starts
  /// with no sort and no filter. Nothing here touches the disk, so a missing or unreadable file
  /// shows its message in the pane.
  public func replaceSource(with file: URL, startDirectory: String) throws {
    record = DataViewerDescription(startDirectory: startDirectory, path: file.path)
    describesFromRecord = false
    restoreWaitsForStart = false

    open(path: file.path, bookmark: nil, restoring: nil)
  }

  private func open(path: String, bookmark: Data?, restoring query: TableQuery?) {
    opening?.cancel()
    openGeneration += 1
    resolvedNotice = nil
    nested?.close()
    nested = nil

    let generation = openGeneration
    session.close()
    refresh()

    opening = Task { [weak self] in
      let result = await SourceResolver.resolve(path: path, bookmark: bookmark)

      guard let self, generation == self.openGeneration, !self.closed else { return }

      self.opening = nil
      self.describesFromRecord = false

      switch result {
      case .success(let resolved):
        self.record.bookmark = resolved.bookmark

        if let movedFrom = resolved.movedFrom {
          self.record.path = movedFrom
          self.resolvedNotice = "Moved. Found at \(movedFrom)."
        }

        self.session.load(.file(resolved.file), restoring: query)

      case .failure(let error):
        self.session.fail(error, restoring: query)
      }
    }
  }

  /// A drop of one file replaces the pane's file. Several files are refused with a message, and the
  /// pane keeps what it showed.
  func handleDrop(_ urls: [URL]) -> Bool {
    guard let file = urls.first else { return false }

    guard urls.count == 1 else {
      host?.applet(
        self, post: .warning,
        text: "Drop one file at a time. The data viewer shows one file in a pane.")
      return false
    }

    do {
      try replaceSource(with: file, startDirectory: SourceStartDirectory.of(file))
      return true
    } catch {
      host?.applet(
        self, post: .error,
        text:
          "\u{201C}\(file.lastPathComponent)\u{201D} could not be opened: \(error.localizedDescription)"
      )
      return false
    }
  }

  private func showOpenPanel() {
    Task { @MainActor [weak self] in
      guard let self else { return }

      await SourceOpening.open(self, picker: SystemOpenPanel.pick)
    }
  }

  // MARK: Applet

  public func start() {
    guard restoreWaitsForStart, let path = record.path else { return }

    restoreWaitsForStart = false
    open(path: path, bookmark: record.bookmark, restoring: record.query)
  }

  public func close() {
    closed = true
    nested?.close()
    nested = nil
    opening?.cancel()
    opening = nil
    session.onChange = nil
    session.close()
  }

  public func detach() {}

  public func reattach() {}

  public func focus() {
    content.focusBody()
  }

  public func apply(_ palette: ThemePalette) {
    self.palette = palette
    nested?.apply(palette)
    content.apply(palette)
  }

  public func describe() -> AppletDescription {
    var description = record

    if !describesFromRecord {
      let query = session.query

      description.sort = query.sort
      description.filter = query.filter.isEmpty ? nil : query.filter
    }

    // The payload always encodes. The fields are plain values, so a failure is a programming error.
    return (try? description.appletDescription())
      ?? AppletDescription(
        type: DataViewerDescription.typeID, version: DataViewerDescription.currentVersion,
        payload: .object([:]))
  }

  // MARK: Display

  private func refresh() {
    guard !closed else { return }

    let fileName = record.path.map { ($0 as NSString).lastPathComponent }
    let query = describesFromRecord ? record.query : session.query

    content.show(
      body(), notices: notices(), filter: query.filter, sort: query.sort)

    let newTitle = fileName ?? Self.untitled
    let newSegments = segmentsForState()
    let titleChanged = newTitle != title

    guard titleChanged || newSegments != segments else { return }

    title = newTitle
    segments = newSegments

    if titleChanged {
      publishedTabs = AppletTabList(
        first: AppletTab(id: publishedTabs.first.id, title: newTitle))
      host?.appletTabsDidChange(self)
    }

    host?.appletDidChange(self)
  }

  private func body() -> DataViewerBody {
    if let failure = failure() {
      return .message(failure)
    }

    if !session.snapshot.columns.isEmpty {
      return .table
    }

    switch session.phase {
    case .idle:
      return .message(
        record.path == nil
          ? "Open a CSV or JSON file, or drop one here."
          : "Opening\u{2026}")

    case .loading:
      return .message("Loading\u{2026}")

    case .loaded:
      return .message("\u{201C}\(title)\u{201D} has no rows.")

    case .stoppedAtBudget, .stoppedLowMemory:
      return .message("Loading stopped because memory is in short supply, so no rows are shown.")

    case .failed:
      return .message("")
    }
  }

  private func failure() -> String? {
    if case .failed(let error) = session.phase {
      return error.errorDescription
    }

    return nil
  }

  private func notices() -> [String] {
    var lines: [String] = []
    let loaded = session.snapshot.rowCount.formatted()

    switch session.phase {
    case .stoppedAtBudget:
      lines.append(
        "Showing the first \(loaded) rows of the file. Sorting, filtering, and search cover only these rows."
      )

    case .stoppedLowMemory:
      lines.append(
        "Loading stopped because memory is low. Showing the first \(loaded) rows of the file. Sorting, filtering, and search cover only these rows."
      )

    default:
      break
    }

    if session.sortSkipped {
      lines.append("There is not enough memory to sort this many rows, so they show in file order.")
    }

    if session.progress.truncatedRows > 0 {
      lines.append("\(session.progress.truncatedRows.formatted()) rows had oversized cells cut.")
    }

    if let resolvedNotice {
      lines.append(resolvedNotice)
    }

    return lines
  }

  private func segmentsForState() -> [AppletSegment] {
    let loaded = session.snapshot.rowCount
    let visible = session.visibleCount
    let filtered = !session.query.isEmpty && visible != loaded

    switch session.phase {
    case .idle, .failed:
      return []

    case .loading:
      let percent = session.progress.fraction.map { " \(Int($0 * 100))%" } ?? ""
      return [
        AppletSegment(
          symbolName: "tablecells", text: "Loading\(percent), \(loaded.formatted()) rows")
      ]

    case .loaded:
      return [
        AppletSegment(
          symbolName: "tablecells",
          text: filtered
            ? "\(visible.formatted()) of \(loaded.formatted()) rows"
            : "\(loaded.formatted()) rows")
      ]

    case .stoppedAtBudget, .stoppedLowMemory:
      return [
        AppletSegment(
          symbolName: "tablecells",
          text: filtered
            ? "\(visible.formatted()) of the first \(loaded.formatted()) rows"
            : "The first \(loaded.formatted()) rows",
          style: .warning)
      ]
    }
  }
}
