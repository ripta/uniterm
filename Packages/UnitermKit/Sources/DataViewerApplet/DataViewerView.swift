import AppKit
import TableData
import Theme

/// What the pane's body shows: a table, or a message in its place.
enum DataViewerBody: Equatable {
  case table
  case message(String)

  /// A file on its way in, before any row shows. The fraction is how much of the file has been
  /// read, or nil while that is not known yet.
  case loading(String, fraction: Double?)
}

/// What the find bar shows: the query in its field and a line about the matches.
struct FindDisplay: Equatable {
  var query = ""
  var status = ""
}

/// The sheets a workbook offers and the one that shows. The picker appears for more than one.
struct SheetDisplay: Equatable {
  var names: [String] = []
  var selected: String?
}

/// A nested cell that the user asked to open: its compact JSON text, a title for it, and where the
/// cell sits.
struct NestedRequest {
  let bytes: [UInt8]
  let title: String
  let rect: NSRect
  let anchor: NSView
}

/// The data viewer's body: a filter field, the table, and a message that stands in for it. It
/// takes a dropped file anywhere in the pane, unless it shows a nested value.
///
/// A double click on a nested cell asks the owner to open it as a table of its own.
@MainActor
final class DataViewerView: NSView, NSTableViewDataSource, NSTableViewDelegate,
  NSSearchFieldDelegate
{
  var onSort: ((ColumnIdentity) -> Void)?
  var onFilter: ((String) -> Void)?
  var onFind: ((String) -> Void)?

  /// Steps to the next match when true, and the previous one when false.
  var onStep: ((Bool) -> Void)?
  var onOpen: (() -> Void)?
  var onExpand: ((NestedRequest) -> Void)?

  /// Gets the name of the sheet the user picked.
  var onSheet: ((String) -> Void)?

  /// Gets the dropped files. Returns false to refuse them.
  var onDrop: (([URL]) -> Bool)?

  private weak var session: TableSession?
  private let isNested: Bool
  let filterField = NSSearchField()
  let findField = NSSearchField()
  let findCountLabel = NSTextField(labelWithString: "")
  let sheetPicker = NSPopUpButton(frame: .zero, pullsDown: false)
  private let findRow = NSStackView()
  private let header = NSStackView()
  private var findVisible = false
  private let scrollView = NSScrollView()
  let tableView = NSTableView()
  private let messageLabel = NSTextField(wrappingLabelWithString: "")
  private let openButton = NSButton(title: "Open\u{2026}", target: nil, action: nil)
  private let messageStack = NSStackView()
  let progress = NSProgressIndicator()
  private var identities: [ColumnIdentity] = []
  private var sort: SortSpec?
  private var palette = ThemePalette.latte
  private(set) var body = DataViewerBody.message("")

  override var isFlipped: Bool { true }

  init(session: TableSession, isNested: Bool = false) {
    self.session = session
    self.isNested = isNested

    super.init(frame: .zero)

    wantsLayer = true
    if !isNested { registerForDraggedTypes([.fileURL]) }

    let suffix = isNested ? "-nested" : ""

    filterField.placeholderString = "Filter rows"
    filterField.sendsWholeSearchString = false
    filterField.sendsSearchStringImmediately = true
    filterField.target = self
    filterField.action = #selector(filterChanged)
    filterField.translatesAutoresizingMaskIntoConstraints = false
    filterField.setAccessibilityIdentifier("data-viewer-filter\(suffix)")

    findField.placeholderString = "Find in rows"
    findField.sendsWholeSearchString = false
    findField.sendsSearchStringImmediately = true
    findField.target = self
    findField.action = #selector(findChanged)
    findField.delegate = self
    findField.setAccessibilityIdentifier("data-viewer-find\(suffix)")

    findCountLabel.font = .systemFont(ofSize: 11)
    findCountLabel.setContentHuggingPriority(.required, for: .horizontal)
    findCountLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
    findCountLabel.setAccessibilityIdentifier("data-viewer-find-count\(suffix)")

    findRow.orientation = .horizontal
    findRow.spacing = 8
    findRow.addArrangedSubview(findField)
    findRow.addArrangedSubview(findCountLabel)

    sheetPicker.target = self
    sheetPicker.action = #selector(sheetPicked)
    sheetPicker.controlSize = .small
    sheetPicker.isHidden = true
    sheetPicker.setAccessibilityIdentifier("data-viewer-sheets")

    tableView.dataSource = self
    tableView.delegate = self
    tableView.style = .plain
    tableView.rowHeight = 22
    tableView.allowsColumnReordering = false
    tableView.allowsMultipleSelection = true
    tableView.columnAutoresizingStyle = .noColumnAutoresizing
    tableView.usesAlternatingRowBackgroundColors = false
    tableView.setAccessibilityIdentifier("data-viewer-table\(suffix)")
    tableView.target = self
    tableView.doubleAction = #selector(cellDoubleClicked)

    scrollView.documentView = tableView
    scrollView.contentView.postsBoundsChangedNotifications = true
    scrollView.contentView.postsFrameChangedNotifications = true

    for (name, object) in [
      (NSView.boundsDidChangeNotification, scrollView.contentView as AnyObject),
      (NSView.frameDidChangeNotification, scrollView.contentView),
      (NSTableView.columnDidResizeNotification, tableView),
    ] {
      NotificationCenter.default.addObserver(
        self, selector: #selector(visibleAreaChanged), name: name, object: object)
    }

    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = true
    scrollView.drawsBackground = true
    scrollView.translatesAutoresizingMaskIntoConstraints = false

    messageLabel.alignment = .center
    messageLabel.font = .systemFont(ofSize: 13)
    messageLabel.setAccessibilityIdentifier("data-viewer-message\(suffix)")

    openButton.target = self
    openButton.action = #selector(openPressed)
    openButton.bezelStyle = .rounded
    openButton.setAccessibilityIdentifier("data-viewer-open")

    messageStack.orientation = .vertical
    messageStack.alignment = .centerX
    messageStack.spacing = 12
    messageStack.translatesAutoresizingMaskIntoConstraints = false
    progress.style = .bar
    progress.minValue = 0
    progress.maxValue = 1
    progress.isHidden = true
    progress.translatesAutoresizingMaskIntoConstraints = false
    progress.setAccessibilityIdentifier("data-viewer-progress\(suffix)")
    progress.setAccessibilityLabel("Reading the file")

    messageStack.addArrangedSubview(messageLabel)
    messageStack.addArrangedSubview(progress)
    messageStack.addArrangedSubview(openButton)

    header.orientation = .vertical
    header.alignment = .leading
    header.spacing = 4
    header.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 0, right: 8)
    header.translatesAutoresizingMaskIntoConstraints = false
    header.addArrangedSubview(sheetPicker)
    header.addArrangedSubview(filterField)
    header.addArrangedSubview(findRow)

    addSubview(header)
    addSubview(scrollView)
    addSubview(messageStack)

    NSLayoutConstraint.activate([
      filterField.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -8),
      findRow.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -8),
      header.topAnchor.constraint(equalTo: topAnchor),
      header.leadingAnchor.constraint(equalTo: leadingAnchor),
      header.trailingAnchor.constraint(equalTo: trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
      scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
      messageStack.centerXAnchor.constraint(equalTo: centerXAnchor),
      messageStack.centerYAnchor.constraint(equalTo: centerYAnchor),
      messageStack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
      messageStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
      progress.widthAnchor.constraint(equalToConstant: 200),
    ])

    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityIdentifier("data-viewer\(suffix)")
    apply(.latte)
    show(
      .message(""), filter: "", sort: nil, find: FindDisplay(), sheets: SheetDisplay())
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override var acceptsFirstResponder: Bool { true }

  /// Puts the keyboard where the body is: the table, or the pane when a message stands in for it.
  func focusBody() {
    window?.makeFirstResponder(body == .table ? tableView : self)
  }

  /// Puts the keyboard in the find field and selects what it holds, so typing replaces the query.
  func showFind() {
    findVisible = true
    findRow.isHidden = false
    window?.makeFirstResponder(findField)
    findField.selectText(nil)
  }

  /// Closes the find bar, drops its query, and hands the keyboard back to the table.
  func hideFind() {
    findVisible = false
    findRow.isHidden = true
    findField.stringValue = ""
    onFind?("")
    window?.makeFirstResponder(body == .table ? tableView : self)
  }

  func focusFilter() {
    window?.makeFirstResponder(filterField)
    filterField.selectText(nil)
  }

  /// Scrolls so the cell at the visible row and column is on screen.
  func reveal(row: Int, column: Int) {
    guard row < tableView.numberOfRows, column < tableView.numberOfColumns else { return }

    tableView.scrollRowToVisible(row)
    tableView.scrollColumnToVisible(column)
  }

  /// Shows the body, and the sort, filter, and find the table carries. Notices about what loaded go
  /// to the status bar, not here.
  func show(
    _ body: DataViewerBody, filter: String, sort: SortSpec?,
    find: FindDisplay = FindDisplay(), sheets: SheetDisplay = SheetDisplay()
  ) {
    self.body = body

    let showsTable = body == .table
    scrollView.isHidden = !showsTable
    filterField.isHidden = !showsTable
    findRow.isHidden = !showsTable || !findVisible
    messageStack.isHidden = showsTable

    switch body {
    case .table:
      progress.stopAnimation(nil)
      progress.isHidden = true

    case .message(let text):
      messageLabel.stringValue = text
      openButton.isHidden = isNested
      progress.stopAnimation(nil)
      progress.isHidden = true

    case .loading(let text, let fraction):
      messageLabel.stringValue = text
      openButton.isHidden = true
      progress.isHidden = false
      progress.isIndeterminate = fraction == nil

      if let fraction {
        progress.stopAnimation(nil)
        progress.doubleValue = fraction
      } else {
        progress.startAnimation(nil)
      }
    }

    showSheets(sheets)

    if filterField.currentEditor() == nil, filterField.stringValue != filter {
      filterField.stringValue = filter
    }

    if findField.currentEditor() == nil, findField.stringValue != find.query {
      findField.stringValue = find.query
    }

    findCountLabel.stringValue = find.status
    findCountLabel.isHidden = find.status.isEmpty

    self.sort = sort
    syncColumns()
    updateIndicators(sort: sort)
    tableView.reloadData()
  }

  /// The picker stays up beside a message too, so a sheet with no rows never traps the user on it.
  private func showSheets(_ sheets: SheetDisplay) {
    sheetPicker.isHidden = sheets.names.count < 2

    guard sheetPicker.itemTitles != sheets.names else {
      sheetPicker.selectItem(withTitle: sheets.selected ?? "")
      return
    }

    sheetPicker.removeAllItems()
    sheetPicker.addItems(withTitles: sheets.names)
    sheetPicker.selectItem(withTitle: sheets.selected ?? "")
  }

  func apply(_ palette: ThemePalette) {
    self.palette = palette

    appearance = NSAppearance(named: palette.flavor == .mocha ? .darkAqua : .aqua)
    layer?.backgroundColor = palette[.base].cgColor
    tableView.backgroundColor = palette[.base].nsColor
    tableView.gridColor = palette[.surface0].nsColor
    messageLabel.textColor = palette[.subtext1].nsColor
    findCountLabel.textColor = palette[.subtext1].nsColor
    tableView.reloadData()
  }

  // MARK: Columns

  /// The most columns one turn of the main run loop adds to the table.
  ///
  /// `addTableColumn` costs time in proportion to the columns already there, so adding 1,000 in one
  /// go held the main thread for close to half a second. The table takes them in batches instead,
  /// one batch a turn, and events run between them. The last batch of a 1,000-column table costs
  /// tens of milliseconds.
  static let columnBatch = 64

  /// The columns the session's snapshot has. The table holds a prefix of them while batches are
  /// still being added.
  private var targetColumns: [TableColumn] = []

  private var columnFillScheduled = false

  /// True while the table holds fewer columns than the snapshot has.
  var isAddingColumns: Bool { identities.count < targetColumns.count }

  private func syncColumns() {
    targetColumns = session?.snapshot.columns ?? []

    if !targetColumns.map(\.identity).starts(with: identities) {
      for column in tableView.tableColumns {
        tableView.removeTableColumn(column)
      }

      identities = []
      columnWindow = nil
    }

    addColumnBatch()
  }

  private func addColumnBatch() {
    let start = identities.count
    let end = min(targetColumns.count, start + Self.columnBatch)

    for index in start..<end {
      let column = DataColumn(index: index)
      column.minWidth = 40
      column.width = 160
      column.resizingMask = .userResizingMask
      tableView.addTableColumn(column)
    }

    if end > start {
      identities += targetColumns[start..<end].map(\.identity)
      columnWindow = nil
    }

    // `tableColumns` bridges a fresh array on each read, so it is read once.
    let tableColumns = tableView.tableColumns

    for (index, column) in targetColumns.enumerated() where index < tableColumns.count {
      if tableColumns[index].title != column.title {
        tableColumns[index].title = column.title
      }
    }

    if end < targetColumns.count, !columnFillScheduled {
      columnFillScheduled = true

      // A zero-delay perform waits for the next turn of the run loop, after pending events.
      perform(#selector(continueColumnFill), with: nil, afterDelay: 0)
    }
  }

  @objc private func continueColumnFill() {
    columnFillScheduled = false

    guard isAddingColumns else { return }

    let before = identities.count
    addColumnBatch()
    updateIndicators(sort: sort)

    var rows = IndexSet()
    tableView.enumerateAvailableRowViews { _, row in rows.insert(row) }

    if !rows.isEmpty {
      tableView.reloadData(
        forRowIndexes: rows, columnIndexes: IndexSet(integersIn: before..<identities.count))
    }
  }

  // MARK: Column window

  /// Columns this far past the visible ones, in visible widths, get cell views ahead of a scroll.
  private static let columnReach = 1

  /// The columns that get cell views, or nil before the table has been measured for them.
  ///
  /// A view-based table makes a cell view for every column of each row it shows, not only the
  /// visible ones. With the 1,000 columns a wide JSON file can have, every reload made thousands
  /// of views and blocked the main thread for about a second. Cells outside this window get no
  /// view. A scroll, a resize, or a column resize moves the window, and the columns that come into
  /// it are reloaded in the rows the table holds.
  private var columnWindow: Range<Int>?

  private var columnWindowRect = NSRect.zero

  /// The column window for the table's visible rect now. It is measured again only when the
  /// visible rect moved.
  private func currentColumnWindow() -> Range<Int> {
    let visible = tableView.visibleRect

    if let columnWindow, visible == columnWindowRect { return columnWindow }

    let window = Self.columnWindow(
      visible: tableView.columnIndexes(in: visible), count: tableView.numberOfColumns)

    columnWindow = window
    columnWindowRect = visible

    return window
  }

  /// The visible columns, widened by `columnReach` times their count on each side. With nothing
  /// visible yet, the first few columns, so a table that has not been laid out still fills.
  static func columnWindow(visible: IndexSet, count: Int) -> Range<Int> {
    guard let first = visible.first, let last = visible.last else { return 0..<min(count, 32) }

    let reach = (last - first + 1) * columnReach

    return max(0, first - reach)..<min(count, last + 1 + reach)
  }

  @objc private func visibleAreaChanged() {
    guard let old = columnWindow else { return }

    // A column resize moves columns under a visible rect that stayed put.
    columnWindowRect = .zero

    let new = currentColumnWindow()

    guard new != old else { return }

    // Columns that left the window are reloaded too, so their views go and a long scroll does not
    // gather a view for every column again.
    let moved = IndexSet(integersIn: new).symmetricDifference(IndexSet(integersIn: old))
      .filteredIndexSet { $0 < tableView.numberOfColumns }

    var rows = IndexSet()
    tableView.enumerateAvailableRowViews { _, row in rows.insert(row) }

    if !rows.isEmpty, !moved.isEmpty {
      tableView.reloadData(forRowIndexes: rows, columnIndexes: moved)
    }
  }

  private func updateIndicators(sort: SortSpec?) {
    for (index, column) in tableView.tableColumns.enumerated() {
      let sorted = sort.flatMap { $0.column == identities[index] ? $0 : nil }

      tableView.setIndicatorImage(
        sorted.map {
          NSImage(
            named: $0.ascending
              ? NSImage.Name("NSAscendingSortIndicator")
              : NSImage.Name("NSDescendingSortIndicator"))
        } ?? nil, in: column)
    }
  }

  // MARK: Table

  func numberOfRows(in tableView: NSTableView) -> Int {
    session?.visibleCount ?? 0
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    guard let session, let column = (tableColumn as? DataColumn)?.index,
      row < session.visibleCount, currentColumnWindow().contains(column)
    else { return nil }

    let cell =
      tableView.makeView(withIdentifier: DataCell.identifier, owner: nil) as? DataCell
      ?? DataCell()

    let source = session.selection.row(at: row)

    switch session.matchState(row: row, column: column) {
    case .current:
      cell.tint = palette[.peach].nsColor.withAlphaComponent(0.6)

    case .match:
      cell.tint = palette[.yellow].nsColor.withAlphaComponent(0.3)

    case .none:
      cell.tint = nil
    }

    switch session.snapshot.kind(row: source, column: column) {
    case .nested:
      cell.label.stringValue = "\u{25B8} " + session.snapshot.text(row: source, column: column)
      cell.restingColor = palette[.blue].nsColor

    case .null:
      cell.label.stringValue = "null"
      cell.restingColor = palette[.overlay1].nsColor

    case .notComputed:
      cell.label.stringValue = "not computed"
      cell.restingColor = palette[.overlay1].nsColor

    default:
      cell.label.stringValue = session.snapshot.text(row: source, column: column)
      cell.restingColor = palette[.text].nsColor
    }

    return cell
  }

  func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
    guard let index = (tableColumn as? DataColumn)?.index, index < identities.count else { return }

    onSort?(identities[index])
  }

  // MARK: Actions

  @objc private func filterChanged() {
    onFilter?(filterField.stringValue)
  }

  @objc private func findChanged() {
    onFind?(findField.stringValue)
  }

  /// Return steps to the next match, Shift-Return to the previous one, and Escape closes the bar.
  /// Both return true so the field does not also send its own action.
  func control(
    _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
  ) -> Bool {
    guard control === findField else { return false }

    switch commandSelector {
    case #selector(NSResponder.insertNewline(_:)):
      onStep?(NSApp.currentEvent?.modifierFlags.contains(.shift) != true)
      return true

    case #selector(NSResponder.cancelOperation(_:)):
      hideFind()
      return true

    default:
      return false
    }
  }

  @objc private func cellDoubleClicked() {
    guard let session, tableView.clickedRow >= 0, tableView.clickedRow < session.visibleCount,
      tableView.clickedColumn >= 0, tableView.clickedColumn < tableView.tableColumns.count
    else { return }

    let source = session.selection.row(at: tableView.clickedRow)
    let column = tableView.clickedColumn

    guard session.snapshot.kind(row: source, column: column) == .nested else { return }

    onExpand?(
      NestedRequest(
        bytes: Array(session.snapshot.cell(row: source, column: column)),
        title: tableView.tableColumns[column].title,
        rect: tableView.frameOfCell(atColumn: column, row: tableView.clickedRow),
        anchor: tableView))
  }

  @objc private func sheetPicked() {
    guard let name = sheetPicker.titleOfSelectedItem else { return }

    onSheet?(name)
  }

  @objc private func openPressed() {
    onOpen?()
  }

  // MARK: Drop

  private func droppedFiles(_ sender: any NSDraggingInfo) -> [URL] {
    let objects = sender.draggingPasteboard.readObjects(
      forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])

    return (objects as? [URL]) ?? []
  }

  override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
    droppedFiles(sender).isEmpty ? [] : .copy
  }

  override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
    onDrop?(droppedFiles(sender)) ?? false
  }
}
