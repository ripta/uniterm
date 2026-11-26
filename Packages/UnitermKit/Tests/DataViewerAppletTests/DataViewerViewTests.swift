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
