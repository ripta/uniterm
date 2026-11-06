import AppKit
import StatusKit
import Theme

/// The expanded status bar: the history of messages, newest first, with each one's level and
/// source. It floats over the pane area against the bar, so opening it never resizes a pane.
///
/// The rows live in a view-based table, so a full history of 500 rows builds only the few cells
/// that are on screen. The panel reports which rows are in its viewport, and the window
/// acknowledges exactly those. Opening the panel acknowledges nothing by itself.
///
/// The panel never takes the keyboard by itself. Until the user asks for it, the table, the filter,
/// and the buttons refuse first responder, so opening or reading the history leaves the keyboard in
/// the focused pane. The Focus Message History command engages the keyboard. The table then takes
/// first responder. The arrow keys move a row cursor, Return runs Focus Pane on that row, Tab
/// reaches the filter and the loss control, and Escape gives the keyboard back to the pane.
///
/// Each row's full text is its label's string value, which is also its tooltip, so a long message
/// that the row cuts short stays readable to assistive technology and on hover.
@MainActor
final class HistoryPanelView: NSView, NSTableViewDataSource, NSTableViewDelegate {
  static let height: CGFloat = 240
  static let rowHeight: CGFloat = 22

  /// Which rows the panel lists.
  enum Filter: Equatable {
    case all
    case pane(UInt64)
  }

  /// Says whether a pane is still in the window. The panel asks again each time it draws a row.
  var isPaneOpen: (UInt64) -> Bool = { _ in false }

  /// Runs with the IDs of the records in the viewport, after each change to the rows or the scroll.
  var onExposed: (([UInt64]) -> Void)?

  /// Runs when the user acknowledges the retention-loss summary.
  var onAcknowledgeLoss: (() -> Void)?

  /// Runs when the user activates Focus Pane on a row. Returns false when the pane is gone.
  var onFocusPane: ((UInt64) -> Bool)?

  /// Runs when the keyboard leaves the panel, so the window can return it to the focused pane.
  var onReleaseKeyboard: (() -> Void)?

  /// Says whether anyone can see the panel's rows. A minimized or covered window cannot show them,
  /// so nothing is acknowledged while this answers false.
  var isObserved: () -> Bool = { true }

  private let filterButton = NSPopUpButton(frame: .zero, pullsDown: false)
  private let lossLabel = NSTextField(labelWithString: "")
  private let lossButton = NSButton(title: "Acknowledge", target: nil, action: nil)
  private let lossStrip = NSStackView()
  let scrollView = NSScrollView()
  private let table = HistoryTableView()
  private var palette: ThemePalette = .latte

  private var messages: [StatusMessage] = []
  private var loss = RetentionLoss()
  private var panes: [HistoryPane] = []
  private var shown: [StatusMessage] = []

  private(set) var filter: Filter = .all

  /// The lines on show, newest first. Tests read it.
  private(set) var lines: [String] = []

  /// The titles of the filter menu, in order. Tests read it.
  var filterTitles: [String] { filterButton.itemTitles }

  override var wantsUpdateLayer: Bool { true }

  override var mouseDownCanMoveWindow: Bool { false }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)

    configureFilter()
    configureLossStrip()
    configureTable()

    let header = NSStackView(views: [filterButton, lossStrip])
    header.orientation = .vertical
    header.alignment = .leading
    header.spacing = 2
    header.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 2, right: 10)
    header.translatesAutoresizingMaskIntoConstraints = false
    addSubview(header)

    scrollView.documentView = table
    scrollView.hasVerticalScroller = true
    scrollView.drawsBackground = false
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(scrollView)

    NSLayoutConstraint.activate([
      header.topAnchor.constraint(equalTo: topAnchor),
      header.leadingAnchor.constraint(equalTo: leadingAnchor),
      header.trailingAnchor.constraint(equalTo: trailingAnchor),
      lossStrip.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -10),
      scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
      scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
      scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
    ])

    scrollView.contentView.postsBoundsChangedNotifications = true
    NotificationCenter.default.addObserver(
      self, selector: #selector(viewportDidChange), name: NSView.boundsDidChangeNotification,
      object: scrollView.contentView)

    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityIdentifier("status-history")
    isHidden = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  isolated deinit {
    NotificationCenter.default.removeObserver(self)
  }

  override func updateLayer() {
    layer?.backgroundColor = palette[.mantle].cgColor
    layer?.borderColor = palette[.surface1].cgColor
    layer?.borderWidth = 1
  }

  private(set) var isLayingOut = false

  /// Reporting from inside layout would refresh the rows, which lays the panel out again from
  /// within its own layout pass. The report waits for the next turn of the main actor.
  override func layout() {
    isLayingOut = true
    super.layout()
    isLayingOut = false
    scheduleExposure()
  }

  private var exposureScheduled = false

  private func scheduleExposure() {
    guard !exposureScheduled else { return }

    exposureScheduled = true

    Task { @MainActor [weak self] in
      self?.exposureScheduled = false
      self?.reportExposure()
    }
  }

  func apply(_ palette: ThemePalette) {
    self.palette = palette
    lossLabel.textColor = palette.color(for: .warning)
    needsDisplay = true
    table.reloadData()
  }

  /// Shows the history, newest first, under the current filter. A filter on a pane that has no
  /// rows left falls back to All.
  func show(
    _ history: [StatusMessage], loss: RetentionLoss = RetentionLoss(), panes: [HistoryPane] = []
  ) {
    messages = history
    self.loss = loss
    self.panes = panes

    if case .pane(let id) = filter, !panes.contains(where: { $0.id == id }) {
      filter = .all
    }

    rebuildFilterMenu()
    updateLossStrip()
    rebuildRows()
  }

  /// Chooses what the panel lists. Tests and the filter menu call it.
  func select(_ filter: Filter) {
    guard filter != self.filter else { return }

    self.filter = filter
    rebuildFilterMenu()
    rebuildRows()
  }

  /// The IDs of the records whose whole row is in the viewport now, newest first. A row that shows
  /// a sliver has not been read.
  var exposedIDs: [UInt64] {
    guard !shown.isEmpty else { return [] }

    let visible = table.visibleRect
    let range = table.rows(in: visible)
    guard range.length > 0 else { return [] }

    let upper = min(range.location + range.length, shown.count)
    guard range.location < upper else { return [] }

    return (range.location..<upper).compactMap { row in
      let rect = table.rect(ofRow: row)
      guard rect.minY >= visible.minY - 0.5, rect.maxY <= visible.maxY + 0.5 else { return nil }

      return shown[row].id
    }
  }

  /// The number of cell views the table has built. A long history builds only the ones in view.
  var builtCellCount: Int {
    table.subviews.reduce(0) { $0 + ($1 is NSTableRowView ? 1 : 0) }
  }

  /// The Focus Pane control of the row that shows `id`, for tests.
  func focusButton(forRecord id: UInt64) -> NSButton? {
    guard let row = shown.firstIndex(where: { $0.id == id }),
      let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? HistoryCellView
    else { return nil }

    return cell.focusButton
  }

  /// The label of the row at `index` in the list, newest first, for tests.
  func rowLabel(at index: Int) -> NSTextField? {
    (table.view(atColumn: 0, row: index, makeIfNecessary: true) as? HistoryCellView)?.label
  }

  var lossAcknowledgeButton: NSButton { lossButton }

  var lossLabelAccessibilityValue: String? { lossLabel.accessibilityValue() }

  var lossLabelToolTip: String? { lossLabel.toolTip }

  /// The filter menu, for the key loop test.
  var filterControl: NSView { filterButton }

  /// The views one Tab walks through from the table, for tests.
  var keyLoop: [NSView] {
    var views: [NSView] = [table]
    var next = table.nextKeyView

    while let view = next, view !== table, views.count < 5 {
      views.append(view)
      next = view.nextKeyView
    }

    return views
  }

  var lossText: String { lossLabel.stringValue }

  // MARK: Setup

  private func configureFilter() {
    filterButton.target = self
    filterButton.action = #selector(filterChanged)
    filterButton.controlSize = .small
    filterButton.font = .systemFont(ofSize: 11)
    filterButton.refusesFirstResponder = true
    filterButton.setAccessibilityIdentifier("history-filter")
    filterButton.setAccessibilityLabel("Filter messages by pane")
  }

  private func configureLossStrip() {
    lossLabel.font = .systemFont(ofSize: 11)
    lossLabel.lineBreakMode = .byTruncatingTail
    lossLabel.maximumNumberOfLines = 1
    lossLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    lossLabel.setAccessibilityIdentifier("history-loss")

    lossButton.target = self
    lossButton.action = #selector(acknowledgeLoss)
    lossButton.controlSize = .small
    lossButton.font = .systemFont(ofSize: 11)
    lossButton.refusesFirstResponder = true
    lossButton.setAccessibilityIdentifier("history-loss-acknowledge")

    lossStrip.setViews([lossLabel, lossButton], in: .leading)
    lossStrip.orientation = .horizontal
    lossStrip.spacing = 8
    lossStrip.isHidden = true
  }

  private func configureTable() {
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("history"))
    column.resizingMask = .autoresizingMask
    table.addTableColumn(column)
    table.headerView = nil
    table.rowHeight = Self.rowHeight
    table.intercellSpacing = NSSize(width: 0, height: 0)
    table.selectionHighlightStyle = .regular
    table.backgroundColor = .clear
    table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
    table.dataSource = self
    table.delegate = self
    table.setAccessibilityIdentifier("history-table")
    table.onActivate = { [weak self] in self?.activateSelectedRow() }
    table.onCancel = { [weak self] in self?.releaseKeyboard() }
  }

  // MARK: Rows

  private func rebuildRows() {
    let matching =
      switch filter {
      case .all: messages
      case .pane(let id): messages.filter { $0.source.paneID == id }
      }

    shown = Array(matching.reversed())
    lines = shown.map(StatusBarContent.historyLine)

    table.reloadData()
    layoutSubtreeIfNeeded()
    reportExposure()
  }

  private func rebuildFilterMenu() {
    let titles = ["All"] + panes.map(menuTitle)

    if filterButton.itemTitles != titles {
      filterButton.removeAllItems()
      filterButton.addItem(withTitle: "All")
      filterButton.lastItem?.representedObject = nil

      for pane in panes {
        filterButton.addItem(withTitle: menuTitle(pane))
        filterButton.lastItem?.representedObject = NSNumber(value: pane.id)
      }
    }

    switch filter {
    case .all:
      filterButton.selectItem(at: 0)

    case .pane(let id):
      if let index = panes.firstIndex(where: { $0.id == id }) {
        filterButton.selectItem(at: index + 1)
      }
    }
  }

  private func menuTitle(_ pane: HistoryPane) -> String {
    let title = "\(pane.name) (pane \(pane.id))"
    return isPaneOpen(pane.id) ? title : "\(title), closed"
  }

  private func updateLossStrip() {
    lossStrip.isHidden = loss.isEmpty
    lossLabel.stringValue = loss.text
    lossLabel.toolTip = loss.text
    lossLabel.setAccessibilityValue(loss.text)
    lossButton.isEnabled = loss.unseenErrors > 0 || loss.unseenWarnings > 0
    updateKeyLoop()
  }

  /// Reports the records in view to `onExposed`, unless the panel is hidden or unobserved.
  func reportExposure() {
    guard !isHidden, isObserved() else { return }

    let ids = exposedIDs
    guard !ids.isEmpty else { return }

    onExposed?(ids)
  }

  // MARK: Keyboard

  /// True while the panel holds the keyboard because the user asked for it.
  private(set) var isKeyboardEngaged = false

  /// The table, then the filter, then the loss control when it shows, then the table again.
  func updateKeyLoop() {
    table.nextKeyView = filterButton
    filterButton.nextKeyView = lossStrip.isHidden || !lossButton.isEnabled ? table : lossButton
    lossButton.nextKeyView = table
  }

  /// Takes the keyboard for the user. The cursor starts on the newest row. Returns false when the
  /// panel is not showing.
  @discardableResult
  func engageKeyboard() -> Bool {
    guard !isHidden, let window else { return false }

    isKeyboardEngaged = true
    table.allowsKeyboard = true
    filterButton.refusesFirstResponder = false
    lossButton.refusesFirstResponder = false
    updateKeyLoop()

    if table.selectedRow < 0, !shown.isEmpty {
      table.selectRowIndexes([0], byExtendingSelection: false)
    }

    return window.makeFirstResponder(table)
  }

  /// Gives the keyboard back. The window returns it to the focused pane.
  func releaseKeyboard() {
    guard isKeyboardEngaged else { return }

    isKeyboardEngaged = false
    table.allowsKeyboard = false
    filterButton.refusesFirstResponder = true
    lossButton.refusesFirstResponder = true
    table.deselectAll(nil)

    if let held = window?.firstResponder as? NSView, held.isDescendant(of: self) {
      window?.makeFirstResponder(nil)
    }

    onReleaseKeyboard?()
  }

  /// Runs Focus Pane for the row under the cursor, as the row's own control does.
  func activateSelectedRow() {
    let row = table.selectedRow

    guard shown.indices.contains(row), let id = shown[row].source.paneID else { return }

    if onFocusPane?(id) == true {
      releaseKeyboard()
    } else {
      table.reloadData(forRowIndexes: IndexSet(integersIn: 0..<shown.count), columnIndexes: [0])
    }
  }

  // MARK: Actions

  @objc private func filterChanged() {
    if let id = (filterButton.selectedItem?.representedObject as? NSNumber)?.uint64Value {
      select(.pane(id))
    } else {
      select(.all)
    }
  }

  @objc private func acknowledgeLoss() {
    onAcknowledgeLoss?()
  }

  @objc private func viewportDidChange() {
    reportExposure()
  }

  @objc private func focusPane(_ sender: NSButton) {
    let row = table.row(for: sender)
    guard shown.indices.contains(row), let id = shown[row].source.paneID else { return }

    if onFocusPane?(id) != true {
      table.reloadData(forRowIndexes: IndexSet(integersIn: 0..<shown.count), columnIndexes: [0])
    }
  }

  // MARK: Table

  func numberOfRows(in tableView: NSTableView) -> Int {
    max(shown.count, 1)
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    let identifier = NSUserInterfaceItemIdentifier("history-cell")
    let cell =
      tableView.makeView(withIdentifier: identifier, owner: self) as? HistoryCellView
      ?? HistoryCellView(identifier: identifier)

    if shown.isEmpty {
      cell.configure(
        text: "No messages yet.", tone: .normal, identifier: "history-empty", palette: palette,
        pane: nil)
      return cell
    }

    let message = shown[row]
    let pane = message.source.paneID
    cell.configure(
      text: lines[row], tone: StatusBarContent.tone(for: message.level),
      identifier: "history-row", palette: palette,
      pane: pane.map { (id: $0, open: isPaneOpen($0)) })
    cell.focusButton.target = self
    cell.focusButton.action = #selector(focusPane(_:))
    return cell
  }

  func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
    isKeyboardEngaged && !shown.isEmpty
  }
}

/// A table that takes the keyboard only after the user engages it. Reading the history must not pull
/// the keyboard out of a pane.
final class HistoryTableView: NSTableView {
  var allowsKeyboard = false
  var onActivate: (() -> Void)?
  var onCancel: (() -> Void)?

  override var acceptsFirstResponder: Bool { allowsKeyboard }

  override func keyDown(with event: NSEvent) {
    switch event.keyCode {
    case 36, 76: onActivate?()
    case 53: onCancel?()
    default: super.keyDown(with: event)
    }
  }

  override func cancelOperation(_ sender: Any?) {
    onCancel?()
  }
}

/// One history row: a single-line label, and a Focus Pane control for a row that came from a pane.
final class HistoryCellView: NSTableCellView {
  let label = NSTextField(labelWithString: "")
  let focusButton = NSButton(title: "Focus Pane", target: nil, action: nil)

  init(identifier: NSUserInterfaceItemIdentifier) {
    super.init(frame: .zero)
    self.identifier = identifier

    label.font = .systemFont(ofSize: 11)
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    label.translatesAutoresizingMaskIntoConstraints = false

    focusButton.controlSize = .small
    focusButton.font = .systemFont(ofSize: 10)
    focusButton.bezelStyle = .rounded
    focusButton.refusesFirstResponder = true
    focusButton.setAccessibilityIdentifier("history-focus-pane")
    focusButton.translatesAutoresizingMaskIntoConstraints = false
    focusButton.setContentHuggingPriority(.required, for: .horizontal)

    addSubview(label)
    addSubview(focusButton)

    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),
      label.trailingAnchor.constraint(lessThanOrEqualTo: focusButton.leadingAnchor, constant: -8),
      focusButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      focusButton.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  func configure(
    text: String, tone: BarTone, identifier: String, palette: ThemePalette,
    pane: (id: UInt64, open: Bool)?
  ) {
    label.stringValue = text
    label.toolTip = text
    label.textColor = palette.color(for: tone)
    label.setAccessibilityIdentifier(identifier)

    focusButton.isHidden = pane == nil
    focusButton.isEnabled = pane?.open ?? false
    focusButton.toolTip = pane?.open == false ? "This pane is closed." : "Focus this pane"
    focusButton.setAccessibilityLabel(
      pane.map { $0.open ? "Focus pane \($0.id)" : "Pane \($0.id) is closed" })
  }
}
