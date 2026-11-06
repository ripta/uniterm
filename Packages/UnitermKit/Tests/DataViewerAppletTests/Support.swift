import AppKit
import AppletKit
import StatusKit
import TableData
import TableTestSupport
import XCTest

@testable import DataViewerApplet

/// Collects what an applet tells its pane.
@MainActor
final class RecordingHost: AppletHost {
  var posts: [(level: StatusLevel, text: String)] = []
  var changes = 0
  var tabChanges = 0

  /// What the applet recorded in the history without a turn on the bar.
  var records: [(level: StatusLevel, text: String)] = []

  /// What the applet delivered with the unseen signal and no turn on the bar.
  var attentions: [(level: StatusLevel, text: String)] = []

  /// What the applet presented again from a record it made earlier, without a new history entry.
  var presented: [(delivery: StatusDelivery, level: StatusLevel, text: String, record: UInt64)] =
    []

  private var lastRecord: UInt64 = 0

  func applet(
    _ applet: any Applet, send delivery: StatusDelivery, level: StatusLevel, text: String,
    presenting record: StatusRecordID?
  ) -> StatusRecordID? {
    if let record {
      presented.append((delivery, level, text, record))
      return record
    }

    switch delivery {
    case .message: posts.append((level, text))
    case .attention: attentions.append((level, text))
    case .historyOnly: records.append((level, text))
    }

    lastRecord += 1
    return lastRecord
  }

  func appletDidExit(_ applet: any Applet) {}

  func appletDidChange(_ applet: any Applet) { changes += 1 }

  func appletTabsDidChange(_ applet: any Applet) { tabChanges += 1 }

  func applet(_ applet: any Applet, confirm request: AppletConfirmation) async -> Bool { false }

  func issueCloseStamp() -> UInt64 { 0 }
}

final class Scratch {
  let url: URL

  init(_ test: XCTestCase) throws {
    url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("uniterm-viewer-\(UUID().uuidString)", isDirectory: true)
      .resolvingSymlinksInPath()

    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

    let folder = url
    test.addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
  }

  @discardableResult
  func write(_ name: String, _ text: String) throws -> URL {
    let file = url.appendingPathComponent(name)
    try Data(text.utf8).write(to: file)
    return file
  }
}

@MainActor
extension XCTestCase {
  func eventually(timeout: Double = 10, _ condition: @escaping @MainActor () -> Bool) async -> Bool
  {
    let deadline = Date().addingTimeInterval(timeout)

    while Date() < deadline {
      if condition() { return true }

      try? await Task.sleep(for: .milliseconds(10))
    }

    return condition()
  }
}

func makeBudget() -> TableBudget {
  TableBudget(limit: 1 << 30, floor: 1 << 20)
}

/// A workbook with the given sheets, each a list of rows of text cells. The applet reads it
/// through the production reader. The archive comes from the shared ZIP fixture writer, with
/// stored entries.
func makeWorkbook(_ sheets: [(name: String, rows: [[String]])]) -> Data {
  let header = #"<?xml version="1.0" encoding="UTF-8"?>"#

  let list = sheets.enumerated().map {
    #"<sheet name="\#($0.element.name)" r:id="rId\#($0.offset + 1)"/>"#
  }.joined()

  let rels = sheets.indices.map {
    #"<Relationship Id="rId\#($0 + 1)" Type="x/worksheet" Target="worksheets/s\#($0 + 1).xml"/>"#
  }.joined()

  var parts = [
    ZipPart(
      "_rels/.rels",
      header
        + #"<Relationships><Relationship Id="r" Type="x/officeDocument" Target="xl/workbook.xml"/></Relationships>"#,
      method: .stored),
    ZipPart(
      "xl/workbook.xml", header + #"<workbook xmlns:r="x"><sheets>\#(list)</sheets></workbook>"#,
      method: .stored),
    ZipPart(
      "xl/_rels/workbook.xml.rels", header + "<Relationships>\(rels)</Relationships>",
      method: .stored),
  ]

  for (index, sheet) in sheets.enumerated() {
    let rows = sheet.rows.map { cells in
      "<row>"
        + cells.map { #"<c t="inlineStr"><is><t>\#($0)</t></is></c>"# }.joined() + "</row>"
    }.joined()

    parts.append(
      ZipPart(
        "xl/worksheets/s\(index + 1).xml",
        header + "<worksheet><sheetData>\(rows)</sheetData></worksheet>", method: .stored))
  }

  return Data(ZipFixture.archive(parts))
}
