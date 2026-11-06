import AppKit
import TableData
import Theme

/// A nested value, shown as a table of its own in a popover over the cell that holds it.
///
/// The value is loaded the way a file is, through the same reader, store, and budget, and it
/// sorts and filters the same way. A cell in it that is nested opens one more popover. Closing the
/// popover releases the rows.
@MainActor
final class NestedTable: NSObject, NSPopoverDelegate {
  private static let size = NSSize(width: 640, height: 380)

  let session: TableSession
  let view: DataViewerView

  private let title: String
  private let budget: TableBudget
  private let popover = NSPopover()
  private var child: NestedTable?
  private var palette: ThemePalette
  private var closed = false

  init(
    bytes: [UInt8], title: String, budget: TableBudget, palette: ThemePalette,
    pageTarget: Int = TableLoader.defaultPageTarget
  ) {
    self.title = title
    self.budget = budget
    self.palette = palette

    session = TableSession(budget: budget, pageTarget: pageTarget)
    view = DataViewerView(session: session, isNested: true)

    super.init()

    view.apply(palette)
    view.frame = NSRect(origin: .zero, size: Self.size)

    view.onSort = { [weak self] column in self?.session.cycleSort(column) }
    view.onFilter = { [weak self] text in self?.session.setFilter(text) }
    view.onExpand = { [weak self] request in self?.expand(request) }
    session.onChange = { [weak self] in self?.refresh() }

    let controller = NSViewController()
    controller.view = view
    controller.preferredContentSize = Self.size

    popover.contentViewController = controller
    popover.behavior = .transient
    popover.delegate = self

    session.load(.embeddedJSON(name: title, bytes: bytes))
  }

  func present(relativeTo rect: NSRect, of anchor: NSView) {
    popover.show(relativeTo: rect, of: anchor, preferredEdge: .maxY)
  }

  func apply(_ palette: ThemePalette) {
    self.palette = palette
    view.apply(palette)
    child?.apply(palette)
  }

  /// Closes the popover and every popover opened from it, and frees the rows.
  func close() {
    guard !closed else { return }

    closed = true
    child?.close()
    child = nil
    session.onChange = nil
    session.close()
    popover.close()
  }

  func popoverDidClose(_ notification: Notification) {
    close()
  }

  private func expand(_ request: NestedRequest) {
    child?.close()

    let next = NestedTable(
      bytes: request.bytes, title: request.title, budget: budget, palette: palette)

    child = next
    next.present(relativeTo: request.rect, of: request.anchor)
  }

  private func refresh() {
    guard !closed else { return }

    view.show(
      body(), notices: notices(), filter: session.query.filter, sort: session.query.sort)
  }

  private func body() -> DataViewerBody {
    if case .failed(let error) = session.phase {
      return .message(error.errorDescription ?? "\u{201C}\(title)\u{201D} could not be opened.")
    }

    if !session.snapshot.columns.isEmpty, !session.stoppedBeforeAnyRow {
      return .table
    }

    switch session.phase {
    case .idle, .loading:
      return .message("Loading\u{2026}")

    case .loaded:
      return .message("\u{201C}\(title)\u{201D} is empty.")

    case .stoppedAtBudget, .stoppedLowMemory:
      return .message("There is not enough memory to open \u{201C}\(title)\u{201D}.")

    case .failed:
      return .message("")
    }
  }

  private func notices() -> [String] {
    DataViewerNotices.lines(
      sortSkipped: session.sortSkipped, truncatedRows: session.progress.truncatedRows)
  }
}
