import Foundation

/// The spreadsheet side of a load. It opens the workbook, picks a sheet, reads the styles and the
/// shared strings, then streams the sheet's rows into the same page store, budget, and snapshots
/// that CSV and JSON use.
///
/// The first row of the sheet that holds anything is the header when every cell in it is a text
/// label. A column with no header is named by its position, and repeated headers keep separate
/// identities, as in a CSV file. A row with no cells that hold anything is dropped.
extension LoadRun {
  mutating func readSpreadsheet(
    from descriptor: Int32, fileSize: Int, path: String, sheet requested: String?
  ) {
    sheet.isActive = true

    var sharedReserved = 0
    let lease = lease
    let limits = limits

    defer { if sharedReserved > 0 { lease.giveBack(sharedReserved) } }

    do {
      let package = try WorkbookPackage(
        descriptor: descriptor, fileSize: fileSize, limits: limits, isCancelled: isCancelled)
      let layout = try package.layout()

      let visible = layout.sheets.filter { !$0.isHidden }
      let listed = visible.isEmpty ? layout.sheets : visible
      let chosen = listed.first { $0.name == requested } ?? listed[0]

      progress.sheets = listed.map(\.name)
      progress.selectedSheet = chosen.name
      progress.totalBytes = package.uncompressedSize(of: chosen.path)
      emit(.snapshot(snapshot(includingPartialPage: false), progress))

      var styles: [NumberStyle] = []

      if let stylesPath = layout.stylesPath {
        let handler = StylesHandler(maxStyles: limits.styles)

        try package.parse(
          stylesPath, cap: limits.metadataBytes, what: "its styles part", handler: handler)

        styles = handler.styles()
      }

      var strings = SharedStrings()

      if let stringsPath = layout.sharedStringsPath {
        let handler = SharedStringsHandler(
          cellBytes: limits.cellBytes, reserve: { lease.reserve($0) })

        defer { sharedReserved += handler.reserved }

        try package.parse(
          stringsPath, cap: limits.sharedStringBytes, what: "its shared strings table",
          handler: handler)

        strings = handler.table
      }

      let handler = SheetHandler(
        strings: strings, styles: styles, date1904: layout.date1904, limits: limits)
      let pump = XMLPump()

      let take = { (row: SheetRow) -> Bool in acceptSheetRow(row, pump: pump) }

      try withoutActuallyEscaping(take) { onRow in
        handler.onRow = onRow

        defer { handler.onRow = nil }

        try package.parse(
          chosen.path, cap: limits.sheetBytes, what: "its sheet", handler: handler, pump: pump)
      }

      guard end == nil else { return }

      progress.bytesRead = progress.totalBytes

      if !sealPage() { return }

      finish(.completed)
    } catch let failure as SpreadsheetFailure {
      finish(failure, path: path)
    } catch {
      finish(.failed(.invalidSpreadsheet(path: path, reason: error.localizedDescription)))
    }
  }

  /// Takes a finished row. Returns false once the load has ended.
  private mutating func acceptSheetRow(_ row: SheetRow, pump: XMLPump) -> Bool {
    sheet.rowCount += 1

    if cancelled(atRow: sheet.rowCount) { return false }

    if row.wasCut { progress.truncatedRows += 1 }

    if sheet.isFirstRow {
      sheet.isFirstRow = false

      if row.allLabels {
        var header = [String](repeating: "", count: (row.cells.last?.column ?? -1) + 1)

        for cell in row.cells {
          header[cell.column] = String(String(decoding: cell.bytes, as: UTF8.self).prefix(512))
        }

        sheet.header = header
        return true
      }
    }

    sheet.columns = max(sheet.columns, (row.cells.last?.column ?? -1) + 1)
    builder.append(typed: row.cells)
    progress.bytesRead = pump.inflatedBytes

    if builder.cost >= pageTarget {
      _ = sealPage()
    }

    publishIfDue()

    return end == nil
  }

  private mutating func finish(_ failure: SpreadsheetFailure, path: String) {
    if isCancelled() {
      finish(.cancelled)
      return
    }

    switch failure {
    case .cancelled:
      finish(.cancelled)

    case .tooLarge(let what):
      finish(.failed(.spreadsheetTooLarge(path: path, what: what)))

    case .refused(.memoryPressure):
      finish(.stoppedLowMemory)

    case .refused(.released):
      finish(.cancelled)

    case .refused:
      finish(.stoppedAtBudget)

    case .invalid(let reason):
      finish(.failed(.invalidSpreadsheet(path: path, reason: reason)))

    case .unsupported(let kind):
      finish(.failed(.unsupportedSpreadsheet(path: path, kind: kind)))

    case .consumerGone:
      finish(.failed(.invalidSpreadsheet(path: path, reason: "its data ended early")))
    }
  }
}

/// What a sheet read keeps between rows.
struct SheetReadState {
  var isActive = false
  var header: [String]?
  var columns = 0
  var isFirstRow = true
  var rowCount = 0
}
