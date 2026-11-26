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
