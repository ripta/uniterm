import AppKit
import GeoData
import Theme

/// A sidebar that lists the file's pins, so the user can find, select, edit, and remove them
/// without hunting on the map.
///
/// The filter matches labels, ignoring case. The list holds what the map holds, and the owner
/// gives it every change through `show(pins:)`.
@MainActor
final class PinListView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
  /// Gets the ID of the pin the user selected in the list.
  var onSelect: ((String) -> Void)?

  /// Gets a double-click or Return on a row.
  var onEdit: ((String) -> Void)?

  /// Gets Add Pin.
  var onAdd: (() -> Void)?

  /// Gets Remove for the selected row.
  var onRemove: ((String) -> Void)?

  let filterField = NSSearchField()
  let table = NSTableView()
  let addButton = NSButton(title: "Add Pin", target: nil, action: nil)
  let removeButton = NSButton(title: "Remove", target: nil, action: nil)
  private let scroll = NSScrollView()
  private let emptyLabel = NSTextField(wrappingLabelWithString: "")
  private var all: [GeoPin] = []
  private(set) var shown: [GeoPin] = []
  private var palette = ThemePalette.latte
  private var selectingFromOwner = false

  static let width = 260.0

  override var isFlipped: Bool { true }

  init() {
    super.init(frame: .zero)

    wantsLayer = true
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityIdentifier("map-pin-list")
    setAccessibilityLabel("Pins")

    filterField.placeholderString = "Filter pins"
    filterField.delegate = self
    filterField.translatesAutoresizingMaskIntoConstraints = false
    filterField.setAccessibilityIdentifier("map-pin-filter")

    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("pin"))
    column.resizingMask = .autoresizingMask
    table.addTableColumn(column)
    table.headerView = nil
    table.rowHeight = 36
    table.style = .sourceList
    table.dataSource = self
    table.delegate = self
    table.target = self
    table.doubleAction = #selector(editClicked)
    table.setAccessibilityIdentifier("map-pin-table")

    scroll.documentView = table
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false
    scroll.translatesAutoresizingMaskIntoConstraints = false

    emptyLabel.font = .systemFont(ofSize: 12)
    emptyLabel.alignment = .center
    emptyLabel.translatesAutoresizingMaskIntoConstraints = false

    addButton.target = self
    addButton.action = #selector(addClicked)
    addButton.setAccessibilityIdentifier("map-pin-add")
    removeButton.target = self
    removeButton.action = #selector(removeClicked)
    removeButton.setAccessibilityIdentifier("map-pin-remove")

    let buttons = NSStackView(views: [addButton, removeButton])
    buttons.spacing = 8
    buttons.translatesAutoresizingMaskIntoConstraints = false

    for view in [filterField, scroll, emptyLabel, buttons] { addSubview(view) }

    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: Self.width),
      filterField.topAnchor.constraint(equalTo: topAnchor, constant: 10),
      filterField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
      filterField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      scroll.topAnchor.constraint(equalTo: filterField.bottomAnchor, constant: 8),
      scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
      scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -8),
      emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
      emptyLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      emptyLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
      buttons.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
      buttons.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
    ])

    render()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  func apply(_ palette: ThemePalette) {
    self.palette = palette

    layer?.backgroundColor = palette[.mantle].cgColor
    emptyLabel.textColor = palette[.subtext0].nsColor
    table.reloadData()
  }

  /// Shows `pins`, keeping the selection on the same pin when it is still there.
  func show(pins: [GeoPin]) {
    let selected = selectedID

    all = pins
    render()

    if let selected { select(id: selected) }
  }

  /// The ID of the pin selected in the list.
  var selectedID: String? {
    shown.indices.contains(table.selectedRow) ? shown[table.selectedRow].id : nil
  }

  /// Selects the row for `id`, as when the user selects the pin on the map. It does not report the
  /// selection back, so the map does not move.
  func select(id: String?) {
    selectingFromOwner = true
    defer { selectingFromOwner = false }

    guard let id, let row = shown.firstIndex(where: { $0.id == id }) else {
      table.deselectAll(nil)
      return
    }

    table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    table.scrollRowToVisible(row)
  }

  /// Narrows the list to labels that hold `text`, ignoring case.
  func filter(_ text: String) {
    filterField.stringValue = text
    render()
  }

  private func render() {
    let needle = filterField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

    shown = needle.isEmpty ? all : all.filter { $0.label.localizedCaseInsensitiveContains(needle) }
    table.reloadData()

    emptyLabel.stringValue =
      all.isEmpty ? "No pins yet. Right-click the map, or press Add Pin." : "No pins match."
    emptyLabel.isHidden = !shown.isEmpty
    removeButton.isEnabled = selectedID != nil
  }

  // MARK: Table

  func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    let pin = shown[row]
    let title = NSTextField(labelWithString: pin.label)
    title.font = .systemFont(ofSize: 13)
    title.lineBreakMode = .byTruncatingTail
    title.textColor = palette[.text].nsColor

    let place = NSTextField(
      labelWithString: String(
        format: "%.4f, %.4f", pin.coordinate.latitude, pin.coordinate.longitude))
    place.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    place.textColor = palette[.subtext0].nsColor

    let stack = NSStackView(views: [title, place])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 1
    stack.setAccessibilityElement(true)
    stack.setAccessibilityRole(.row)
    stack.setAccessibilityLabel(pin.label)

    return stack
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    removeButton.isEnabled = selectedID != nil

    if !selectingFromOwner, let id = selectedID { onSelect?(id) }
  }

  func controlTextDidChange(_ notification: Notification) {
    render()
  }

  @objc private func editClicked() {
    if let id = selectedID { onEdit?(id) }
  }

  @objc private func addClicked() {
    onAdd?()
  }

  @objc private func removeClicked() {
    if let id = selectedID { onRemove?(id) }
  }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 51 || event.keyCode == 117, let id = selectedID {
      onRemove?(id)
    } else if event.keyCode == 36, let id = selectedID {
      onEdit?(id)
    } else {
      super.keyDown(with: event)
    }
  }
}
