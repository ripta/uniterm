import AppKit
import AppletKit
import AppletTestSupport
import StatusKit
import TableData
import TableTestSupport
import XCTest

@testable import DataViewerApplet

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
