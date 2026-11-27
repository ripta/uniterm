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
/// A double click on a nested cell asks the owner to open it as a table of its own. A double click
/// on any other cell with a value asks the owner to show that value whole.
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

  /// Gets a text or number cell the user asked to read in full.
  var onShowValue: ((ValueRequest) -> Void)?

  /// Gets the name of the sheet the user picked.
  var onSheet: ((String) -> Void)?

  /// Gets the dropped files. Returns false to refuse them.
  var onDrop: (([URL]) -> Bool)?

  private weak var session: TableSession?
  private let isNested: Bool
  let filterField = FilterField()
  let filterCaption = makeCaption(
    "FILTER", label: "Filter", identifier: "data-viewer-filter-caption")
  let findField = NSSearchField()
  let findCountLabel = NSTextField(labelWithString: "")
  let sheetPicker = NSPopUpButton(frame: .zero, pullsDown: false)
  let findRow: FindStrip
  private(set) var colors = FilterFindColors(.latte)
  private let header = NSStackView()
  private var findVisible = false
  private let scrollView = NSScrollView()
  let tableView = NSTableView()
  private let messageLabel = NSTextField(wrappingLabelWithString: "")
  private let openButton = NSButton(title: "Open\u{2026}", target: nil, action: nil)
  private let messageStack = NSStackView()
  let progress = NSProgressIndicator()
  let edgeJumps = EdgeJumps()
  private let fileRow = NSStackView()
  let fileNameLabel = NSTextField(labelWithString: "")
  let headerOpenButton = NSButton(title: "Open\u{2026}", target: nil, action: nil)

  /// The name of the open file, shown beside the filter. Nil for a nested table.
  var fileName: String? {
    didSet {
      guard fileName != oldValue else { return }

      fileNameLabel.stringValue = fileName ?? ""
      fileNameLabel.toolTip = fileName
    }
  }
  private var identities: [ColumnIdentity] = []
  private var sort: SortSpec?
  private var filter = ""
  private var palette = ThemePalette.latte
  private(set) var body = DataViewerBody.message("")

  override var isFlipped: Bool { true }

  init(session: TableSession, isNested: Bool = false) {
    self.session = session
    self.isNested = isNested

    let suffix = isNested ? "-nested" : ""
    findRow = FindStrip(field: findField, count: findCountLabel, suffix: suffix)

    super.init(frame: .zero)

    wantsLayer = true
    if !isNested { registerForDraggedTypes([.fileURL]) }

    filterField.placeholderString = "Filter rows"
    filterField.setAccessibilityLabel("Filter rows")
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
    findField.setAccessibilityLabel("Find in rows")

    findCountLabel.font = .systemFont(ofSize: 11)
    findCountLabel.setContentHuggingPriority(.required, for: .horizontal)
    findCountLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
    findCountLabel.setAccessibilityIdentifier("data-viewer-find-count\(suffix)")

    findRow.onStep = { [weak self] forward in self?.onStep?(forward) }
    findRow.onDone = { [weak self] in self?.hideFind() }

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

    NotificationCenter.default.addObserver(
      self, selector: #selector(columnResized), name: NSTableView.columnDidResizeNotification,
      object: tableView)

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
    fileNameLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
    fileNameLabel.lineBreakMode = .byTruncatingMiddle
    fileNameLabel.setContentHuggingPriority(.required, for: .horizontal)
    fileNameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    fileNameLabel.setAccessibilityIdentifier("data-viewer-file-name")

    headerOpenButton.target = self
    headerOpenButton.action = #selector(openPressed)
    headerOpenButton.bezelStyle = .rounded
    headerOpenButton.controlSize = .small
    headerOpenButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    headerOpenButton.setContentHuggingPriority(.required, for: .horizontal)
    headerOpenButton.setContentCompressionResistancePriority(.required, for: .horizontal)
    headerOpenButton.toolTip = "Open another file in this pane"
    headerOpenButton.setAccessibilityIdentifier("data-viewer-open-file")
    headerOpenButton.setAccessibilityLabel("Open another file in this pane")

    fileRow.orientation = .horizontal
    fileRow.spacing = 8
    fileRow.alignment = .centerY
    fileRow.addArrangedSubview(fileNameLabel)
    fileRow.addArrangedSubview(filterCaption)
    fileRow.addArrangedSubview(filterField)
    fileRow.addArrangedSubview(headerOpenButton)
    fileRow.setCustomSpacing(12, after: fileNameLabel)
    fileRow.setCustomSpacing(4, after: filterCaption)

    // A nested table belongs to its cell, not to a file, and a pane-local Open there would replace
    // the file under the popover.
    fileNameLabel.isHidden = isNested
    headerOpenButton.isHidden = isNested

    header.addArrangedSubview(sheetPicker)
    header.addArrangedSubview(fileRow)
    header.addArrangedSubview(findRow)

    addSubview(header)
    addSubview(scrollView)
    addSubview(messageStack)

    edgeJumps.install(in: self, over: scrollView, suffix: suffix)
    edgeJumps.onJump = { [weak self] edge in self?.jump(to: edge) }

    NSLayoutConstraint.activate([
      fileRow.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -8),
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
    fileRow.isHidden = !showsTable
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
    findRow.update(hasMatch: session?.matches.isEmpty == false)

    self.filter = filter
    filterField.count = filterCount(filter)

    self.sort = sort
    syncColumns()
    updateIndicators(sort: sort)
    tableView.reloadData()
    updateEdgeJumps()
  }

  /// The count inside the filter field, such as "5 of 250 rows", while a filter hides rows. Empty
  /// with no filter, where the status bar already gives the count. After a load that stopped
  /// early, it reads "of the first N rows", as the status bar does.
  private func filterCount(_ filter: String) -> String {
    guard let session, !filter.isEmpty else { return "" }

    let shown = session.visibleCount.formatted()
    let loaded = session.snapshot.rowCount.formatted()
    let cut = session.phase == .stoppedAtBudget || session.phase == .stoppedLowMemory

    return cut ? "\(shown) of the first \(loaded) rows" : "\(shown) of \(loaded) rows"
  }

  /// The parts of a cell's text the filter matched, ignoring case as the filter does.
  private func filterMatches(in text: String) -> [NSRange] {
    guard !filter.isEmpty else { return [] }

    let string = text as NSString
    var ranges: [NSRange] = []
    var search = NSRange(location: 0, length: string.length)

    while search.length > 0 {
      let found = string.range(of: filter, options: .caseInsensitive, range: search)

      guard found.location != NSNotFound, found.length > 0 else { break }

      ranges.append(found)
      search = NSRange(location: NSMaxRange(found), length: string.length - NSMaxRange(found))
    }

    return ranges
  }

  // MARK: Edge jumps

  /// Shows or hides the arrows for the table's size now. The view calls it as rows arrive and as
  /// the visible area moves or resizes.
  func updateEdgeJumps() {
    let clip = scrollView.contentView.bounds
    let rowStride = tableView.rowHeight + tableView.intercellSpacing.height

    edgeJumps.update(
      showsTable: body == .table, columns: targetColumns.count,
      visibleColumns: tableView.columnIndexes(in: tableView.visibleRect).count,
      rows: tableView.numberOfRows,
      visibleRows: rowStride > 0 ? Int(clip.height / rowStride) : 0)
  }

  func jump(to edge: EdgeJumps.Edge) {
    switch edge {
    case .firstColumn:
      if tableView.numberOfColumns > 0 { tableView.scrollColumnToVisible(0) }

    case .lastColumn:
      if tableView.numberOfColumns > 0 {
        tableView.scrollColumnToVisible(tableView.numberOfColumns - 1)
      }

    case .firstRow:
      if tableView.numberOfRows > 0 { tableView.scrollRowToVisible(0) }

    case .lastRow:
      if tableView.numberOfRows > 0 { tableView.scrollRowToVisible(tableView.numberOfRows - 1) }
    }
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
    colors = FilterFindColors(palette)
    messageLabel.textColor = palette[.subtext1].nsColor
    findCountLabel.textColor = Contrast.readable(
      palette[.subtext1].nsColor, on: colors.findStrip, toward: palette[.text].nsColor)
    fileNameLabel.textColor = palette[.subtext1].nsColor
    filterCaption.textColor = colors.filterAccent
    filterField.countLabel.textColor = palette[.subtext1].nsColor
    findRow.apply(colors)
    edgeJumps.apply(palette)
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
      userSizedColumns = []
      columnsSizedWithoutRows = []
    }

    refitColumnsSizedWithoutRows()
    addColumnBatch()
  }

  // MARK: Column widths

  /// Columns the user resized by hand. Their width is theirs from then on.
  private var userSizedColumns = Set<Int>()

  /// Columns that were sized before any row had loaded, from their header alone. They are sized
  /// once more when the first rows arrive.
  private var columnsSizedWithoutRows = Set<Int>()

  /// True while the view sets widths itself, so the resize it causes is not taken for the user's.
  private var settingWidths = false

  private func fittedWidth(_ index: Int, column: NSTableColumn) -> CGFloat {
    guard let snapshot = session?.snapshot else { return ColumnWidth.minimum }

    if snapshot.rowCount == 0 { columnsSizedWithoutRows.insert(index) }

    return ColumnWidth.fitted(
      title: targetColumns[index].title, column: index, in: snapshot,
      headerFont: column.headerCell.font ?? .systemFont(ofSize: NSFont.smallSystemFontSize),
      cellFont: DataCell.numberFont)
  }

  private func refitColumnsSizedWithoutRows() {
    guard (session?.snapshot.rowCount ?? 0) > 0, !columnsSizedWithoutRows.isEmpty else { return }

    let pending = columnsSizedWithoutRows.subtracting(userSizedColumns)
    columnsSizedWithoutRows = []

    let tableColumns = tableView.tableColumns

    settingWidths = true
    defer { settingWidths = false }

    for index in pending where index < tableColumns.count {
      tableColumns[index].width = fittedWidth(index, column: tableColumns[index])
    }
  }

  @objc private func columnResized(_ notification: Notification) {
    guard !settingWidths,
      let column = notification.userInfo?["NSTableColumn"] as? DataColumn
    else { return }

    userSizedColumns.insert(column.index)
    columnsSizedWithoutRows.remove(column.index)
  }

  private func addColumnBatch() {
    let start = identities.count
    let end = min(targetColumns.count, start + Self.columnBatch)

    for index in start..<end {
      let column = DataColumn(index: index)
      column.minWidth = 40
      column.width = fittedWidth(index, column: column)
      column.resizingMask = .userResizingMask
      tableView.addTableColumn(column)
    }

    if end > start {
      identities += targetColumns[start..<end].map(\.identity)
      columnWindow = nil
    }

    // `tableColumns` bridges a fresh array on each read, so it is read once.
    let tableColumns = tableView.tableColumns

    let numeric = session?.numericColumns ?? IndexSet()

    for (index, column) in targetColumns.enumerated() where index < tableColumns.count {
      let tableColumn = tableColumns[index]

      if tableColumn.title != column.title {
        tableColumn.title = column.title
      }

      let alignment: NSTextAlignment = numeric.contains(index) ? .right : .left

      if tableColumn.headerCell.alignment != alignment {
        tableColumn.headerCell.alignment = alignment
        tableView.headerView?.needsDisplay = true
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
    updateEdgeJumps()

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
    case .current: cell.setTint(colors.strongMatch, ink: colors.inkOnStrongMatch)
    case .match: cell.setTint(colors.paleMatch, ink: colors.inkOnPaleMatch)
    case .none: cell.setTint(nil, ink: nil)
    }

    let text = ColumnWidth.displayText(
      session.snapshot, row: source, column: column, limit: 2_000)

    cell.label.stringValue = text
    let numeric = session.numericColumns.contains(column)
    cell.label.alignment = numeric ? .right : .left
    cell.label.font = numeric ? DataCell.numberFont : DataCell.font

    let kind = session.snapshot.kind(row: source, column: column)

    switch kind {
    case .nested: cell.restingColor = palette[.blue].nsColor
    case .null, .notComputed: cell.restingColor = palette[.overlay1].nsColor
    default: cell.restingColor = palette[.text].nsColor
    }

    // Null and a missing formula result hold no text, so the filter never matched their words.
    let matchable = kind != .null && kind != .notComputed
    cell.setUnderlines(matchable ? filterMatches(in: text) : [], color: colors.filterUnderline)

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
    openCell(row: tableView.clickedRow, column: tableView.clickedColumn)
  }

  /// Opens the cell at a visible row and column. A nested cell opens as a table of its own. Text,
  /// a number, or a boolean opens as its whole value. An empty or absent cell opens nothing.
  func openCell(row: Int, column: Int) {
    guard let session, row >= 0, row < session.visibleCount, column >= 0,
      column < tableView.numberOfColumns
    else { return }

    let source = session.selection.row(at: row)
    let title = tableView.tableColumns[column].title
    let rect = tableView.frameOfCell(atColumn: column, row: row)
    let bytes = session.snapshot.cell(row: source, column: column)

    switch session.snapshot.kind(row: source, column: column) {
    case .nested:
      onExpand?(NestedRequest(bytes: Array(bytes), title: title, rect: rect, anchor: tableView))

    case .text, .string, .number, .bool:
      guard !bytes.isEmpty else { return }

      onShowValue?(
        ValueRequest(
          text: String(decoding: bytes, as: UTF8.self), title: title, rect: rect,
          anchor: tableView))

    case .null, .missing, .notComputed:
      return
    }
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
