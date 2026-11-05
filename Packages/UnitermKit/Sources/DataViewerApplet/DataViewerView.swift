import AppKit
import TableData
import Theme

/// What the pane's body shows: a table, or a message in its place.
enum DataViewerBody: Equatable {
  case table
  case message(String)
}

/// The data viewer's body: a filter field, a notice line, the table, and a message that stands in
/// for the table. It takes a dropped file anywhere in the pane.
@MainActor
final class DataViewerView: NSView, NSTableViewDataSource, NSTableViewDelegate {
  var onSort: ((ColumnIdentity) -> Void)?
  var onFilter: ((String) -> Void)?
  var onOpen: (() -> Void)?

  /// Gets the dropped files. Returns false to refuse them.
  var onDrop: (([URL]) -> Bool)?

  private weak var session: TableSession?
  let filterField = NSSearchField()
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

  init(session: TableSession) {
    self.session = session

    super.init(frame: .zero)

    wantsLayer = true
    registerForDraggedTypes([.fileURL])

    filterField.placeholderString = "Filter rows"
    filterField.sendsWholeSearchString = false
    filterField.sendsSearchStringImmediately = true
    filterField.target = self
    filterField.action = #selector(filterChanged)
    filterField.translatesAutoresizingMaskIntoConstraints = false
    filterField.setAccessibilityIdentifier("data-viewer-filter")

    noticeLabel.font = .systemFont(ofSize: 11)
    noticeLabel.translatesAutoresizingMaskIntoConstraints = false
    noticeLabel.setAccessibilityIdentifier("data-viewer-notice")

    tableView.dataSource = self
    tableView.delegate = self
    tableView.style = .plain
    tableView.rowHeight = 22
    tableView.allowsColumnReordering = false
    tableView.allowsMultipleSelection = true
    tableView.columnAutoresizingStyle = .noColumnAutoresizing
    tableView.usesAlternatingRowBackgroundColors = false
    tableView.setAccessibilityIdentifier("data-viewer-table")

    scrollView.documentView = tableView
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = true
    scrollView.drawsBackground = true
    scrollView.translatesAutoresizingMaskIntoConstraints = false

    messageLabel.alignment = .center
    messageLabel.font = .systemFont(ofSize: 13)
    messageLabel.setAccessibilityIdentifier("data-viewer-message")

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

    addSubview(filterField)
    addSubview(noticeLabel)
    addSubview(scrollView)
    addSubview(messageStack)

    NSLayoutConstraint.activate([
      filterField.topAnchor.constraint(equalTo: topAnchor, constant: 8),
      filterField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      filterField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      noticeLabel.topAnchor.constraint(equalTo: filterField.bottomAnchor, constant: 4),
      noticeLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
      noticeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      scrollView.topAnchor.constraint(equalTo: noticeLabel.bottomAnchor, constant: 4),
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
    setAccessibilityIdentifier("data-viewer")
    apply(.latte)
    show(.message(""), notices: [], filter: "", sort: nil)
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

  /// Shows the body, the notice lines, and the sort and filter the table carries.
  func show(_ body: DataViewerBody, notices: [String], filter: String, sort: SortSpec?) {
    self.body = body

    let showsTable = body == .table
    scrollView.isHidden = !showsTable
    filterField.isHidden = !showsTable
    messageStack.isHidden = showsTable

    if case .message(let text) = body {
      messageLabel.stringValue = text
      openButton.isHidden = false
    }

    noticeLabel.stringValue = notices.joined(separator: " ")
    noticeLabel.isHidden = notices.isEmpty || !showsTable

    if filterField.currentEditor() == nil, filterField.stringValue != filter {
      filterField.stringValue = filter
    }

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

    field.stringValue = session.snapshot.text(row: session.selection.row(at: row), column: column)
    field.textColor = palette[.text].nsColor
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
