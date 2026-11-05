import AppKit
import AppletKit
import StatusKit
import TableData
import XCTest

@testable import DataViewerApplet

/// Collects what an applet tells its pane.
@MainActor
final class RecordingHost: AppletHost {
  var posts: [(level: StatusLevel, text: String)] = []
  var changes = 0
  var tabChanges = 0

  func applet(_ applet: any Applet, post level: StatusLevel, text: String) {
    posts.append((level, text))
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

/// A workbook with the given sheets, each a list of rows of text cells, written as a ZIP archive
/// of stored entries. The applet reads it through the production reader. Each entry carries
/// its checksum, which the reader verifies.
func makeWorkbook(_ sheets: [(name: String, rows: [[String]])]) -> Data {
  let header = #"<?xml version="1.0" encoding="UTF-8"?>"#

  let list = sheets.enumerated().map {
    #"<sheet name="\#($0.element.name)" r:id="rId\#($0.offset + 1)"/>"#
  }.joined()

  let rels = sheets.indices.map {
    #"<Relationship Id="rId\#($0 + 1)" Type="x/worksheet" Target="worksheets/s\#($0 + 1).xml"/>"#
  }.joined()

  var parts: [(String, String)] = [
    (
      "_rels/.rels",
      header
        + #"<Relationships><Relationship Id="r" Type="x/officeDocument" Target="xl/workbook.xml"/></Relationships>"#
    ),
    ("xl/workbook.xml", header + #"<workbook xmlns:r="x"><sheets>\#(list)</sheets></workbook>"#),
    ("xl/_rels/workbook.xml.rels", header + "<Relationships>\(rels)</Relationships>"),
  ]

  for (index, sheet) in sheets.enumerated() {
    let rows = sheet.rows.map { cells in
      "<row>"
        + cells.map { #"<c t="inlineStr"><is><t>\#($0)</t></is></c>"# }.joined() + "</row>"
    }.joined()

    parts.append(
      (
        "xl/worksheets/s\(index + 1).xml",
        header + "<worksheet><sheetData>\(rows)</sheetData></worksheet>"
      ))
  }

  func le(_ value: Int, _ width: Int) -> [UInt8] {
    (0..<width).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
  }

  func crc(_ bytes: [UInt8]) -> Int {
    var value: UInt32 = 0xFFFF_FFFF

    for byte in bytes {
      value ^= UInt32(byte)

      for _ in 0..<8 {
        value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
      }
    }

    return Int(value ^ 0xFFFF_FFFF)
  }

  var file: [UInt8] = []
  var directory: [UInt8] = []

  for (name, text) in parts {
    let body = Array(text.utf8)
    let nameBytes = Array(name.utf8)
    let offset = file.count

    file += le(0x0403_4B50, 4) + le(20, 2) + le(0, 2) + le(0, 2) + le(0, 4) + le(crc(body), 4)
    file += le(body.count, 4) + le(body.count, 4) + le(nameBytes.count, 2) + le(0, 2)
    file += nameBytes + body

    directory += le(0x0201_4B50, 4) + le(20, 2) + le(20, 2) + le(0, 2) + le(0, 2) + le(0, 4)
    directory += le(crc(body), 4) + le(body.count, 4) + le(body.count, 4) + le(nameBytes.count, 2)
    directory += le(0, 2) + le(0, 2) + le(0, 2) + le(0, 2) + le(0, 4) + le(offset, 4) + nameBytes
  }

  let end =
    le(0x0605_4B50, 4) + le(0, 2) + le(0, 2) + le(parts.count, 2) + le(parts.count, 2)
    + le(directory.count, 4) + le(file.count, 4) + le(0, 2)

  return Data(file + directory + end)
}
