import AppKit
import TableData
import Theme

/// What the pane's body shows: a table, or a message in its place.
enum DataViewerBody: Equatable {
  case table
  case message(String)
}

/// What the find bar shows: the query in its field and a line about the matches.
struct FindDisplay: Equatable {
  var query = ""
  var status = ""
}

/// A nested cell that the user asked to open: its compact JSON text, a title for it, and where the
/// cell sits.
struct NestedRequest {
  let bytes: [UInt8]
  let title: String
  let rect: NSRect
  let anchor: NSView
}

/// The data viewer's body: a filter field, a notice line, the table, and a message that stands in
/// for the table. It takes a dropped file anywhere in the pane, unless it shows a nested value.
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

  /// Gets the dropped files. Returns false to refuse them.
  var onDrop: (([URL]) -> Bool)?

  private weak var session: TableSession?
  private let isNested: Bool
  let filterField = NSSearchField()
  let findField = NSSearchField()
  let findCountLabel = NSTextField(labelWithString: "")
  private let findRow = NSStackView()
  private let header = NSStackView()
  private var findVisible = false
  private let noticeLabel = NSTextField(wrappingLabelWithString: "")
  private let scrollView = NSScrollView()
  private let tableView = NSTableView()
  private let messageLabel = NSTextField(wrappingLabelWithString: "")
  private let openButton = NSButton(title: "Open\u{2026}", target: nil, action: nil)
  private let messageStack = NSStackView()
  private var identities: [ColumnIdentity] = []
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

    noticeLabel.font = .systemFont(ofSize: 11)
    noticeLabel.setAccessibilityIdentifier("data-viewer-notice\(suffix)")

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
    messageStack.addArrangedSubview(messageLabel)
    messageStack.addArrangedSubview(openButton)

    header.orientation = .vertical
    header.alignment = .leading
    header.spacing = 4
    header.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 0, right: 8)
    header.translatesAutoresizingMaskIntoConstraints = false
    header.addArrangedSubview(filterField)
    header.addArrangedSubview(findRow)
    header.addArrangedSubview(noticeLabel)

    addSubview(header)
    addSubview(scrollView)
    addSubview(messageStack)

    NSLayoutConstraint.activate([
      filterField.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -8),
      findRow.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -8),
      noticeLabel.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -10),
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
    ])

    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityIdentifier("data-viewer\(suffix)")
    apply(.latte)
    show(.message(""), notices: [], filter: "", sort: nil, find: FindDisplay())
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

  /// Shows the body, the notice lines, and the sort, filter, and find the table carries.
  func show(
    _ body: DataViewerBody, notices: [String], filter: String, sort: SortSpec?,
    find: FindDisplay = FindDisplay()
  ) {
    self.body = body

    let showsTable = body == .table
    scrollView.isHidden = !showsTable
    filterField.isHidden = !showsTable
    findRow.isHidden = !showsTable || !findVisible
    messageStack.isHidden = showsTable

    if case .message(let text) = body {
      messageLabel.stringValue = text
      openButton.isHidden = isNested
    }

    noticeLabel.stringValue = notices.joined(separator: " ")
    noticeLabel.isHidden = notices.isEmpty || !showsTable

    if filterField.currentEditor() == nil, filterField.stringValue != filter {
      filterField.stringValue = filter
    }

    if findField.currentEditor() == nil, findField.stringValue != find.query {
      findField.stringValue = find.query
    }

    findCountLabel.stringValue = find.status
    findCountLabel.isHidden = find.status.isEmpty

    syncColumns()
    updateIndicators(sort: sort)
    tableView.reloadData()
  }

  func apply(_ palette: ThemePalette) {
    self.palette = palette

    appearance = NSAppearance(named: palette.flavor == .mocha ? .darkAqua : .aqua)
    layer?.backgroundColor = palette[.base].cgColor
    tableView.backgroundColor = palette[.base].nsColor
    tableView.gridColor = palette[.surface0].nsColor
    messageLabel.textColor = palette[.subtext1].nsColor
    noticeLabel.textColor = palette[.yellow].nsColor
    findCountLabel.textColor = palette[.subtext1].nsColor
    tableView.reloadData()
  }

  // MARK: Columns

  private func syncColumns() {
    let columns = session?.snapshot.columns ?? []
    let next = columns.map(\.identity)

    if next != identities {
      if !next.starts(with: identities) {
        for column in tableView.tableColumns {
          tableView.removeTableColumn(column)
        }

        identities = []
      }

      for index in identities.count..<next.count {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c\(index)"))
        column.minWidth = 40
        column.width = 160
        column.resizingMask = .userResizingMask
        tableView.addTableColumn(column)
      }

      identities = next
    }

    for (index, column) in columns.enumerated() where index < tableView.tableColumns.count {
      tableView.tableColumns[index].title = column.title
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
    guard let session, let tableColumn,
      let column = tableView.tableColumns.firstIndex(of: tableColumn),
      row < session.visibleCount
    else { return nil }

    let identifier = NSUserInterfaceItemIdentifier("cell")
    let field =
      tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTextField
      ?? {
        let field = NSTextField(labelWithString: "")
        field.identifier = identifier
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.font = .systemFont(ofSize: 12)
        return field
      }()

    let source = session.selection.row(at: row)

    switch session.matchState(row: row, column: column) {
    case .current:
      field.drawsBackground = true
      field.backgroundColor = palette[.peach].nsColor.withAlphaComponent(0.6)

    case .match:
      field.drawsBackground = true
      field.backgroundColor = palette[.yellow].nsColor.withAlphaComponent(0.3)

    case .none:
      field.drawsBackground = false
    }

    switch session.snapshot.kind(row: source, column: column) {
    case .nested:
      field.stringValue = "\u{25B8} " + session.snapshot.text(row: source, column: column)
      field.textColor = palette[.blue].nsColor

    case .null:
      field.stringValue = "null"
      field.textColor = palette[.overlay1].nsColor

    default:
      field.stringValue = session.snapshot.text(row: source, column: column)
      field.textColor = palette[.text].nsColor
    }

    return field
  }

  func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
    guard let index = tableView.tableColumns.firstIndex(of: tableColumn), index < identities.count
    else { return }

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
