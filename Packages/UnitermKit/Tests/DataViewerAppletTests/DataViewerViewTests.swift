import AppKit
import TableData
import Theme
import XCTest

@testable import DataViewerApplet

/// The table's cells as the user sees them: their colors, widths, and alignment, read from the
/// views the table makes for its rows.
@MainActor
final class DataViewerViewTests: XCTestCase {
  private func hosted(_ view: NSView, width: CGFloat = 800, height: CGFloat = 400) -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    window.layoutIfNeeded()
    addTeardownBlock { window.close() }

    return window
  }

  /// The text field a row shows at a column, with the row selected and emphasized the way a
  /// focused table draws it.
  private func emphasizedField(_ table: NSTableView, row: Int, column: Int) -> NSTextField? {
    table.layoutSubtreeIfNeeded()

    guard let rowView = table.rowView(atRow: row, makeIfNecessary: true) else { return nil }

    rowView.isSelected = true
    rowView.isEmphasized = true

    let cell = rowView.view(atColumn: column)

    return (cell as? NSTableCellView)?.textField ?? cell as? NSTextField
  }

  // MARK: Selection

  /// Catches cell text drawn in a fixed palette color over the blue of a selected row. Dark text,
  /// the nested-cell blue, and the muted null color all vanish there on the light palette. Every
  /// kind of cell must reach text contrast against the selection, in the pane and in a nested
  /// popover's table. It cannot prove how the row view paints, only the colors the cells ask for.
  func testASelectedRowsTextIsReadableOnTheLightPalette() async throws {
    let scratch = try Scratch(self)
    let file = try scratch.write(
      "kinds.json", #"[{"name":"ann","list":[1,2],"gone":null,"n":3}]"#)
    let applet = DataViewerApplet(startDirectory: nil, budget: makeBudget())
    _ = hosted(applet.view)

    applet.apply(.latte)
    try applet.replaceSource(with: file, startDirectory: scratch.url.path)
    _ = await eventually { applet.session.phase == .loaded }

    let nested = NestedTable(
      bytes: Array(#"[{"x":"y","z":null,"w":[1]}]"#.utf8), title: "items", budget: makeBudget(),
      palette: .latte)
    addTeardownBlock { nested.close() }
    _ = hosted(nested.view)
    _ = await eventually { nested.session.phase == .loaded }

    let selection = Self.resolved(.selectedContentBackgroundColor, in: applet.view)

    for (view, columns) in [(applet.content, 4), (nested.view, 3)] {
      for column in 0..<columns {
        guard let field = emphasizedField(view.tableView, row: 0, column: column),
          let color = field.textColor
        else { return XCTFail("no cell at column \(column)") }

        let ratio = Self.contrast(Self.resolved(color, in: view), selection)
        XCTAssertGreaterThanOrEqual(
          ratio, 4.5, "\(field.stringValue) at column \(column) reads at \(ratio):1")
      }
    }
  }

  /// Catches a cell that keeps its selected color after the selection moves away, which would draw
  /// white text on the light background.
  func testADeselectedRowGetsItsPaletteColorBack() async throws {
    let scratch = try Scratch(self)
    let file = try scratch.write("a.csv", "name\nann\n")
    let applet = DataViewerApplet(startDirectory: nil, budget: makeBudget())
    _ = hosted(applet.view)

    applet.apply(.latte)
    try applet.replaceSource(with: file, startDirectory: scratch.url.path)
    _ = await eventually { applet.session.phase == .loaded }

    let table = applet.content.tableView
    guard let field = emphasizedField(table, row: 0, column: 0),
      let rowView = table.rowView(atRow: 0, makeIfNecessary: false)
    else { return XCTFail("no cell") }

    rowView.isSelected = false

    XCTAssertEqual(field.textColor, ThemePalette.latte[.text].nsColor)
  }

  // MARK: Wide tables

  /// Five objects of 1,100 keys each, which fill the 1,000-column cap and its `(more keys)` cell.
  private func wideJSON(_ scratch: Scratch) throws -> URL {
    let rows = (0..<5).map { row in
      "{" + (0..<1_100).map { #""key\#($0)":"value \#(row)-\#($0)""# }.joined(separator: ",")
        + "}"
    }

    return try scratch.write("wide.json", "[" + rows.joined(separator: ",") + "]")
  }

  private func cellCount(_ table: NSTableView, row: Int) -> Int {
    table.rowView(atRow: row, makeIfNecessary: false)?.subviews.filter { $0 is DataCell }.count
      ?? 0
  }

  /// Catches a table that makes a cell view for every column of each row it shows. A view-based
  /// table does that by default, and with 1,000 columns each reload made thousands of views on the
  /// main thread. The cells stay near the visible columns, and a scroll to the far edge fills the
  /// cells there and lets the first ones go.
  func testAWideTableMakesCellsOnlyNearTheVisibleColumns() async throws {
    let scratch = try Scratch(self)
    let file = try wideJSON(scratch)
    let applet = DataViewerApplet(startDirectory: nil, budget: makeBudget())
    let window = hosted(applet.view, width: 900, height: 500)

    try applet.replaceSource(with: file, startDirectory: scratch.url.path)
    _ = await eventually { applet.session.phase == .loaded && !applet.content.isAddingColumns }

    let table = applet.content.tableView
    XCTAssertEqual(table.numberOfColumns, 1_001)

    window.layoutIfNeeded()

    let visible = table.columnIndexes(in: table.visibleRect).count
    XCTAssertGreaterThan(cellCount(table, row: 0), 0)
    XCTAssertLessThanOrEqual(cellCount(table, row: 0), 3 * visible + 2)

    table.scrollColumnToVisible(1_000)
    window.layoutIfNeeded()

    let last = table.rowView(atRow: 0, makeIfNecessary: false)?.view(atColumn: 1_000) as? DataCell
    XCTAssertNotNil(last, "no cell at the far edge after the scroll")
    XCTAssertNil(table.rowView(atRow: 0, makeIfNecessary: false)?.view(atColumn: 0))
    XCTAssertLessThanOrEqual(cellCount(table, row: 0), 3 * visible + 2)
  }

  /// Catches a table that adds all of a wide file's columns in one turn of the run loop.
  /// `addTableColumn` grows slower with each column, so 1,000 at once held the main thread for
  /// close to half a second. The first turn adds one batch, and the rest follow.
  func testAWideTableAddsItsColumnsInBatches() async throws {
    let scratch = try Scratch(self)
    let session = TableSession(budget: makeBudget())
    session.load(.file(try wideJSON(scratch)))
    _ = await eventually { session.phase == .loaded }

    // The view's first show runs in its initializer, against the loaded session.
    let view = DataViewerView(session: session)
    XCTAssertEqual(view.tableView.numberOfColumns, DataViewerView.columnBatch)

    let filled = await eventually { view.tableView.numberOfColumns == 1_001 }
    XCTAssertTrue(filled)
    XCTAssertEqual(view.tableView.tableColumns.last?.title, "(more keys)")
  }

  /// Catches a pane that says only "Loading" while a file opens, or that forgets which file. The
  /// pane names the file from the moment the open starts.
  func testAFileOnItsWayInNamesItself() async throws {
    let scratch = try Scratch(self)
    let file = try scratch.write("people.csv", "name\nann\n")
    let applet = DataViewerApplet(startDirectory: nil, budget: makeBudget())

    try applet.replaceSource(with: file, startDirectory: scratch.url.path)

    guard case .loading(let text, _) = applet.content.body else {
      return XCTFail("no loading state: \(applet.content.body)")
    }

    XCTAssertEqual(text, "Opening people.csv\u{2026}")
    XCTAssertFalse(applet.content.progress.isHidden)

    _ = await eventually { applet.session.phase == .loaded }
    XCTAssertEqual(applet.content.body, .table)
    XCTAssertTrue(applet.content.progress.isHidden)
  }

  // MARK: Column widths

  /// Catches columns that all start at one fixed width. A short column wastes room and a long one
  /// cuts its text early. Each starts as wide as its header and its widest sampled value, within
  /// the bounds, and the long one stops at the maximum so its popover carries the rest.
  func testColumnsStartAsWideAsTheirContent() async throws {
    let scratch = try Scratch(self)
    let long = String(repeating: "word ", count: 80)
    let file = try scratch.write(
      "a.csv", "id,city,note\n1,Lisbon,short\n22,Ulaanbaatar,\(long)\n")
    let applet = DataViewerApplet(startDirectory: nil, budget: makeBudget())
    _ = hosted(applet.view)

    try applet.replaceSource(with: file, startDirectory: scratch.url.path)
    _ = await eventually { applet.session.phase == .loaded }

    let widths = applet.content.tableView.tableColumns.map(\.width)
    XCTAssertEqual(widths.count, 3)
    XCTAssertEqual(widths[0], ColumnWidth.minimum, "a two-digit column starts at the minimum")
    XCTAssertGreaterThan(widths[1], widths[0])
    XCTAssertLessThan(widths[1], ColumnWidth.maximum)
    XCTAssertEqual(widths[2], ColumnWidth.maximum)

    let cityText = ("Ulaanbaatar" as NSString).size(withAttributes: [.font: DataCell.font]).width
    XCTAssertGreaterThanOrEqual(widths[1], cityText + ColumnWidth.cellPadding)
  }

  /// Catches a numeric column measured in the plain font and then drawn in tabular digits, which
  /// are wider, so its numbers end in an ellipsis.
  func testANumericColumnIsWideEnoughForItsTabularDigits() async throws {
    let scratch = try Scratch(self)
    let file = try scratch.write("a.csv", "n\n1111111111\n2\n")
    let applet = DataViewerApplet(startDirectory: nil, budget: makeBudget())
    _ = hosted(applet.view)

    try applet.replaceSource(with: file, startDirectory: scratch.url.path)
    _ = await eventually { applet.session.numericColumns == IndexSet([0]) }

    let needed =
      ("1111111111" as NSString).size(withAttributes: [.font: DataCell.numberFont]).width
      + ColumnWidth.cellPadding

    XCTAssertGreaterThanOrEqual(applet.content.tableView.tableColumns[0].width, needed)
  }

  /// Catches a width the view sets again over one the user chose. A column resized by hand keeps
  /// its width through later refreshes, such as a filter.
  func testAColumnResizedByHandKeepsItsWidth() async throws {
    let scratch = try Scratch(self)
    let file = try scratch.write("a.csv", "id,city\n1,Lisbon\n2,Oslo\n")
    let applet = DataViewerApplet(startDirectory: nil, budget: makeBudget())
    _ = hosted(applet.view)

    try applet.replaceSource(with: file, startDirectory: scratch.url.path)
    _ = await eventually { applet.session.phase == .loaded }

    let column = applet.content.tableView.tableColumns[1]
    column.width = 250

    applet.session.setFilter("o")
    _ = await eventually { applet.session.visibleCount == 2 }

    XCTAssertEqual(column.width, 250)
  }

  // MARK: Alignment

  /// Catches numbers set flush left, where their places do not line up. A numeric column's cells
  /// and its header sit on the right, and a text column stays on the left.
  func testANumericColumnIsRightAligned() async throws {
    let scratch = try Scratch(self)
    let file = try scratch.write("a.csv", "name,amount\nann,3\nbob,1250.5\n")
    let applet = DataViewerApplet(startDirectory: nil, budget: makeBudget())
    _ = hosted(applet.view)

    try applet.replaceSource(with: file, startDirectory: scratch.url.path)
    _ = await eventually { applet.session.numericColumns == IndexSet([1]) }

    let table = applet.content.tableView
    table.layoutSubtreeIfNeeded()

    let cells = (0..<2).map {
      table.rowView(atRow: 0, makeIfNecessary: true)?.view(atColumn: $0) as? DataCell
    }

    XCTAssertEqual(cells[0]?.label.alignment, .left)
    XCTAssertEqual(cells[1]?.label.alignment, .right)
    XCTAssertEqual(table.tableColumns[0].headerCell.alignment, .left)
    XCTAssertEqual(table.tableColumns[1].headerCell.alignment, .right)
  }

  // MARK: Whole values

  private func privatePasteboard() -> NSPasteboard {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("uniterm-test-\(UUID().uuidString)"))
    addTeardownBlock { pasteboard.releaseGlobally() }

    return pasteboard
  }

  /// Catches a long cell that the table cuts with no way to read the rest. A double click opens
  /// the whole value, past the table's own 2,000-byte cut, and Copy puts all of it on the
  /// pasteboard the pane was given. The test never touches the system clipboard.
  func testOpeningATextCellShowsAndCopiesItsWholeValue() async throws {
    let scratch = try Scratch(self)
    let long = String(repeating: "abcdefghij", count: 400) + "END"
    let file = try scratch.write("a.csv", "id,note\n7,\(long)\n")
    let pasteboard = privatePasteboard()
    let applet = DataViewerApplet(
      startDirectory: nil, budget: makeBudget(), pasteboard: pasteboard)
    _ = hosted(applet.view)

    try applet.replaceSource(with: file, startDirectory: scratch.url.path)
    _ = await eventually { applet.session.phase == .loaded }

    applet.content.openCell(row: 0, column: 1)

    let popover = try XCTUnwrap(applet.valuePopover)
    XCTAssertEqual(popover.textView.string, long)
    XCTAssertFalse(popover.textView.isEditable)
    XCTAssertTrue(popover.textView.isSelectable)

    popover.copyValue()
    XCTAssertEqual(pasteboard.string(forType: .string), long)
    XCTAssertEqual(popover.copyButton.title, "Copied")
  }

  /// Catches a nested cell that opens as text, and an empty cell that opens an empty popover. A
  /// nested cell keeps its table, and an empty one opens nothing.
  func testOnlyCellsWithAPlainValueOpenAsText() async throws {
    let scratch = try Scratch(self)
    let file = try scratch.write("a.json", #"[{"n":12,"list":[1],"gone":null}]"#)
    let applet = DataViewerApplet(
      startDirectory: nil, budget: makeBudget(), pasteboard: privatePasteboard())
    _ = hosted(applet.view)

    try applet.replaceSource(with: file, startDirectory: scratch.url.path)
    _ = await eventually { applet.session.phase == .loaded }

    applet.content.openCell(row: 0, column: 0)
    XCTAssertEqual(applet.valuePopover?.textView.string, "12")

    var expanded = 0
    let showValue = applet.content.onShowValue
    applet.content.onExpand = { _ in expanded += 1 }
    applet.content.onShowValue = { request in
      XCTFail("\(request.title) opened as text")
      showValue?(request)
    }

    applet.content.openCell(row: 0, column: 1)
    applet.content.openCell(row: 0, column: 2)
    XCTAssertEqual(expanded, 1)
  }

  // MARK: The file row

  /// Catches a pane that shows a table with no way to tell which file it is, and no way to open
  /// another without the File menu. The row beside the filter names the file, and its Open button
  /// runs the pane-local Open, which replaces the file.
  func testTheFileRowNamesTheFileAndItsOpenButtonReplacesIt() async throws {
    let scratch = try Scratch(self)
    let first = try scratch.write("first.csv", "a\n1\n")
    let second = try scratch.write("second.csv", "b\n2\n")
    var asked = 0
    let applet = DataViewerApplet(
      startDirectory: scratch.url.path, budget: makeBudget(),
      picker: { _, _ in
        asked += 1
        return [second]
      })
    _ = hosted(applet.view)

    try applet.replaceSource(with: first, startDirectory: scratch.url.path)
    _ = await eventually { applet.session.phase == .loaded }

    XCTAssertEqual(applet.content.fileNameLabel.stringValue, "first.csv")
    XCTAssertFalse(applet.content.headerOpenButton.isHidden)

    applet.content.headerOpenButton.performClick(nil)

    let replaced = await eventually {
      applet.title == "second.csv" && applet.session.phase == .loaded
    }
    XCTAssertTrue(replaced)
    XCTAssertEqual(asked, 1)
    XCTAssertEqual(applet.content.fileNameLabel.stringValue, "second.csv")
  }

  /// Catches a nested popover that offers to open a file, which would replace the file under it.
  func testANestedTableHasNoFileRowControls() {
    let nested = NestedTable(
      bytes: Array(#"[{"x":1}]"#.utf8), title: "items", budget: makeBudget(), palette: .latte)
    addTeardownBlock { nested.close() }

    XCTAssertTrue(nested.view.headerOpenButton.isHidden)
    XCTAssertTrue(nested.view.fileNameLabel.isHidden)
  }

  // MARK: Edge jumps

  private func jumpHidden(_ view: DataViewerView) -> [EdgeJumps.Edge: Bool] {
    view.edgeJumps.buttons.mapValues(\.isHidden)
  }

  /// Catches arrows that cover a small table, and arrows missing from a wide one. The column pair
  /// shows when the columns pass ten times the columns in view, and the row pair stays hidden for
  /// five rows. The last-column arrow scrolls the last column into view, and the first-column
  /// arrow brings the first one back.
  func testAWideTableShowsTheColumnArrowsAndTheyReachBothEdges() async throws {
    let scratch = try Scratch(self)
    let applet = DataViewerApplet(startDirectory: nil, budget: makeBudget())
    let window = hosted(applet.view, width: 900, height: 500)

    try applet.replaceSource(with: try wideJSON(scratch), startDirectory: scratch.url.path)
    _ = await eventually { applet.session.phase == .loaded && !applet.content.isAddingColumns }
    window.layoutIfNeeded()
    applet.content.updateEdgeJumps()

    let hidden = jumpHidden(applet.content)
    XCTAssertEqual(hidden[.firstColumn], false)
    XCTAssertEqual(hidden[.lastColumn], false)
    XCTAssertEqual(hidden[.firstRow], true)
    XCTAssertEqual(hidden[.lastRow], true)

    let table = applet.content.tableView
    applet.content.edgeJumps.buttons[.lastColumn]?.performClick(nil)
    XCTAssertTrue(table.columnIndexes(in: table.visibleRect).contains(1_000))

    applet.content.edgeJumps.buttons[.firstColumn]?.performClick(nil)
    XCTAssertTrue(table.columnIndexes(in: table.visibleRect).contains(0))

    for edge in EdgeJumps.Edge.allCases {
      XCTAssertEqual(applet.content.edgeJumps.buttons[edge]?.accessibilityLabel(), edge.label)
    }
  }

  /// Catches row arrows that never follow the pane's size. A tall file in a short pane shows them,
  /// and the same file in a pane tall enough to hold a tenth of it hides them again.
  func testTheRowArrowsFollowThePanesHeight() async throws {
    let scratch = try Scratch(self)
    var text = "n\n"
    for index in 0..<500 { text += "\(index)\n" }

    let file = try scratch.write("tall.csv", text)
    let applet = DataViewerApplet(startDirectory: nil, budget: makeBudget())
    let window = hosted(applet.view, width: 600, height: 300)

    try applet.replaceSource(with: file, startDirectory: scratch.url.path)
    _ = await eventually { applet.session.phase == .loaded }
    window.layoutIfNeeded()
    applet.content.updateEdgeJumps()

    XCTAssertEqual(jumpHidden(applet.content)[.lastRow], false)
    XCTAssertEqual(jumpHidden(applet.content)[.lastColumn], true)

    applet.content.edgeJumps.buttons[.lastRow]?.performClick(nil)
    let table = applet.content.tableView
    XCTAssertTrue(table.rows(in: table.visibleRect).contains(499))

    window.setContentSize(NSSize(width: 600, height: 1_400))
    window.layoutIfNeeded()

    let hid = await eventually { self.jumpHidden(applet.content)[.lastRow] == true }
    XCTAssertTrue(hid, "the row arrows stayed after the pane grew")
  }

  // MARK: Filter and find

  /// Catches a caption, a count, or a match's text that does not reach text contrast on either
  /// flavor. Each accent and each tint is derived from the palette, so both flavors are checked.
  func testTheFilterAndFindColorsReadOnBothPalettes() {
    for palette in [ThemePalette.latte, .mocha] {
      let colors = FilterFindColors(palette)
      let base = palette[.base].nsColor
      let name = "\(palette.flavor)"

      XCTAssertGreaterThanOrEqual(Contrast.ratio(colors.filterAccent, base), 4.5, name)
      XCTAssertGreaterThanOrEqual(Contrast.ratio(colors.findAccent, colors.findStrip), 4.5, name)
      XCTAssertGreaterThanOrEqual(
        Contrast.ratio(colors.inkOnStrongMatch, colors.strongMatch), 4.5, name)
      XCTAssertGreaterThanOrEqual(
        Contrast.ratio(colors.inkOnPaleMatch, colors.paleMatch), 4.5, name)

      let view = DataViewerView(session: TableSession(budget: makeBudget()))
      view.apply(palette)

      let count = try? XCTUnwrap(view.findCountLabel.textColor)
      XCTAssertGreaterThanOrEqual(
        Contrast.ratio(count ?? .clear, colors.findStrip), 4.5, "\(name) find count")
    }
  }

  /// Catches a find match whose tint goes blue under the selection, or whose text turns white
  /// on amber. A tinted cell covers the row's blue, so its ink holds under the emphasized style.
  /// The current match is the strong amber and the others the pale one.
  func testAFindMatchKeepsItsAmberAndInkUnderTheSelection() async throws {
    let scratch = try Scratch(self)
    let file = try scratch.write("a.csv", "city\nRome\nRomeo\n")
    let applet = DataViewerApplet(startDirectory: nil, budget: makeBudget())
    _ = hosted(applet.view)

    applet.apply(.latte)
    try applet.replaceSource(with: file, startDirectory: scratch.url.path)
    _ = await eventually { applet.session.phase == .loaded }

    applet.content.onFind?("rom")
    _ = await eventually { applet.session.matches.count == 2 }

    let colors = applet.content.colors
    let table = applet.content.tableView

    for (row, tint) in [(0, colors.strongMatch), (1, colors.paleMatch)] {
      guard let field = emphasizedField(table, row: row, column: 0),
        let cell = field.superview as? DataCell
      else { return XCTFail("no cell at row \(row)") }

      XCTAssertEqual(cell.tint, tint)
      XCTAssertEqual(field.textColor, cell.tintInk)
      XCTAssertGreaterThanOrEqual(Contrast.ratio(field.textColor ?? .clear, tint), 4.5)
    }
  }

  /// Catches a filter whose matched text is not marked in the rows it keeps, or whose mark
  /// vanishes on the selection. The matched letters carry the underline, ignoring case, in mauve
  /// at rest and in the selection's text color on the emphasized blue. The field shows the count.
  func testTheFilterUnderlinesWhatItMatchedAndCountsTheRows() async throws {
    let scratch = try Scratch(self)
    let file = try scratch.write("a.csv", "city\nOSLO\nLisbon\nRome\n")
    let applet = DataViewerApplet(startDirectory: nil, budget: makeBudget())
    _ = hosted(applet.view)

    applet.apply(.latte)
    try applet.replaceSource(with: file, startDirectory: scratch.url.path)
    _ = await eventually { applet.session.phase == .loaded }

    applet.session.setFilter("os")
    _ = await eventually { applet.session.visibleCount == 1 }

    XCTAssertEqual(applet.content.filterField.count, "1 of 3 rows")

    let table = applet.content.tableView
    table.layoutSubtreeIfNeeded()

    let cell = try XCTUnwrap(
      table.rowView(atRow: 0, makeIfNecessary: true)?.view(atColumn: 0) as? DataCell)
    XCTAssertEqual(cell.label.stringValue, "OSLO")
    XCTAssertEqual(cell.label.underlines, [NSRange(location: 0, length: 2)])
    XCTAssertEqual(cell.currentUnderlineColor, applet.content.colors.filterUnderline)

    cell.backgroundStyle = .emphasized
    XCTAssertEqual(cell.currentUnderlineColor, .alternateSelectedControlTextColor)

    applet.session.setFilter("")
    _ = await eventually { applet.session.visibleCount == 3 }
    XCTAssertEqual(applet.content.filterField.count, "")
  }

  /// Catches a filter count that forgets the load stopped early. After a budget stop it reads "of
  /// the first N rows", as the status bar does. VoiceOver reaches the count inside the field.
  func testTheFilterCountNamesAStoppedLoadAndIsReachable() async throws {
    let scratch = try Scratch(self)
    var text = "id,v\n"
    for index in 0..<5_000 { text += "\(index),row number \(index)\n" }

    let file = try scratch.write("big.csv", text)
    let applet = DataViewerApplet(
      startDirectory: nil, budget: TableBudget(limit: 40_000, floor: 8_000), pageTarget: 2_000)
    _ = hosted(applet.view)

    try applet.replaceSource(with: file, startDirectory: scratch.url.path)
    _ = await eventually { applet.session.phase == .stoppedAtBudget }

    applet.session.setFilter("number 1")
    _ = await eventually { applet.session.visibleCount < applet.session.snapshot.rowCount }

    let loaded = applet.session.snapshot.rowCount.formatted()
    let count = applet.content.filterField.count
    XCTAssertTrue(count.hasSuffix(" of the first \(loaded) rows"), count)

    let children = applet.content.filterField.accessibilityChildren() ?? []
    XCTAssertTrue(
      children.contains { ($0 as AnyObject) === applet.content.filterField.countLabel },
      "the count is not among the field's accessibility children")
  }

  /// Catches a find strip whose buttons do nothing. Next and previous step the match, and Done
  /// closes the strip and clears the query. Each control and caption has a label for VoiceOver.
  func testTheFindStripStepsAndCloses() async throws {
    let scratch = try Scratch(self)
    let file = try scratch.write("a.csv", "city\nRome\nRomeo\n")
    let applet = DataViewerApplet(startDirectory: nil, budget: makeBudget())
    _ = hosted(applet.view)

    try applet.replaceSource(with: file, startDirectory: scratch.url.path)
    _ = await eventually { applet.session.phase == .loaded }

    applet.showFind()
    applet.content.onFind?("rom")
    _ = await eventually { applet.session.matches.count == 2 }

    let strip = applet.content.findRow
    XCTAssertFalse(strip.isHidden)
    XCTAssertTrue(strip.nextButton.isEnabled)

    strip.nextButton.performClick(nil)
    XCTAssertEqual(applet.session.currentMatch, 1)

    strip.previousButton.performClick(nil)
    XCTAssertEqual(applet.session.currentMatch, 0)

    for control in [strip.caption, strip.previousButton, strip.nextButton, strip.doneButton]
      as [NSView]
    {
      XCTAssertFalse(control.accessibilityLabel()?.isEmpty ?? true)
    }
    XCTAssertEqual(applet.content.filterCaption.accessibilityLabel(), "Filter")

    strip.doneButton.performClick(nil)
    XCTAssertTrue(strip.isHidden)
    XCTAssertEqual(applet.session.findQuery, "")
  }

  // MARK: Color math

  private static func resolved(_ color: NSColor, in view: NSView) -> NSColor {
    var result = color

    view.effectiveAppearance.performAsCurrentDrawingAppearance {
      result = color.usingColorSpace(.sRGB) ?? color
    }

    return result
  }

  /// The WCAG contrast ratio of two opaque colors. A translucent foreground is blended over the
  /// background first.
  static func contrast(_ foreground: NSColor, _ background: NSColor) -> Double {
    let alpha = Double(foreground.alphaComponent)

    func channel(_ value: CGFloat, _ under: CGFloat) -> Double {
      let blended = alpha * Double(value) + (1 - alpha) * Double(under)

      return blended <= 0.03928 ? blended / 12.92 : pow((blended + 0.055) / 1.055, 2.4)
    }

    func luminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
      0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    let front = luminance(
      channel(foreground.redComponent, background.redComponent),
      channel(foreground.greenComponent, background.greenComponent),
      channel(foreground.blueComponent, background.blueComponent))

    let back = luminance(
      channel(background.redComponent, background.redComponent),
      channel(background.greenComponent, background.greenComponent),
      channel(background.blueComponent, background.blueComponent))

    return (max(front, back) + 0.05) / (min(front, back) + 0.05)
  }
}
