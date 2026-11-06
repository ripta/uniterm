import Foundation
import TableTestSupport

@testable import TableData

private let le16 = ZipFixture.le16
private let le32 = ZipFixture.le32

/// A sheet for `Workbook.bytes`: its name and the XML inside `<sheetData>`.
struct SheetSpec {
  var name: String
  var rows: String
  var isHidden = false

  init(_ name: String, _ rows: String, isHidden: Bool = false) {
    self.name = name
    self.rows = rows
    self.isHidden = isHidden
  }
}

enum Workbook {
  static let header = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n"

  /// A workbook as ZIP bytes. `styles` holds each cell style's number format id, in order, and
  /// `formats` the custom format codes by id.
  static func bytes(
    sheets: [SheetSpec], strings: [String]? = nil, styles: [Int] = [0],
    formats: [Int: String] = [:], date1904: Bool = false, extra: [ZipPart] = [],
    stringsXML: String? = nil
  ) -> [UInt8] {
    let sheetList = sheets.enumerated().map { index, sheet in
      let state = sheet.isHidden ? #" state="hidden""# : ""
      return
        #"<sheet name="\#(sheet.name)" sheetId="\#(index + 1)"\#(state) r:id="rId\#(index + 1)"/>"#
    }.joined()

    let dateAttribute = date1904 ? " date1904=\"1\"" : ""

    let workbook =
      header
      + #"<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" "#
      + #"xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">"#
      + #"<workbookPr\#(dateAttribute)/><sheets>\#(sheetList)</sheets></workbook>"#

    let relationships =
      sheets.indices.map {
        #"<Relationship Id="rId\#($0 + 1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet\#($0 + 1).xml"/>"#
      }.joined()
      + #"<Relationship Id="rIdStyles" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>"#
      + #"<Relationship Id="rIdStrings" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/>"#

    var parts = [
      ZipPart("[Content_Types].xml", header + "<Types/>"),
      ZipPart(
        "_rels/.rels",
        header
          + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>"#
      ),
      ZipPart("xl/workbook.xml", workbook),
      ZipPart(
        "xl/_rels/workbook.xml.rels",
        header
          + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\#(relationships)</Relationships>"#
      ),
      ZipPart("xl/styles.xml", stylesXML(styles, formats)),
    ]

    let table =
      stringsXML
      ?? (header + "<sst>" + (strings ?? []).map { "<si><t>\($0)</t></si>" }.joined() + "</sst>")

    parts.append(ZipPart("xl/sharedStrings.xml", table))

    for (index, sheet) in sheets.enumerated() {
      parts.append(
        ZipPart(
          "xl/worksheets/sheet\(index + 1).xml",
          header
            + #"<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>\#(sheet.rows)</sheetData></worksheet>"#
        ))
    }

    return ZipFixture.archive(parts + extra)
  }

  static func stylesXML(_ ids: [Int], _ formats: [Int: String]) -> String {
    let codes = formats.sorted { $0.key < $1.key }.map {
      #"<numFmt numFmtId="\#($0.key)" formatCode="\#($0.value.replacingOccurrences(of: "\"", with: "&quot;"))"/>"#
    }.joined()

    return header + "<styleSheet><numFmts count=\"\(formats.count)\">\(codes)</numFmts>"
      + "<cellStyleXfs count=\"1\"><xf numFmtId=\"14\"/></cellStyleXfs>"
      + "<cellXfs count=\"\(ids.count)\">"
      + ids.map { "<xf numFmtId=\"\($0)\"/>" }.joined() + "</cellXfs></styleSheet>"
  }

  /// A row of cells, written as the file would write them.
  static func row(_ number: Int, _ cells: String) -> String {
    #"<row r="\#(number)">\#(cells)</row>"#
  }
}

/// A compound file with the named directory entries, which is all the loader reads.
enum CompoundFixture {
  static func bytes(streams: [String]) -> [UInt8] {
    var header = [UInt8](repeating: 0, count: 512)

    header.replaceSubrange(0..<8, with: [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])
    header.replaceSubrange(30..<32, with: le16(9))
    header.replaceSubrange(44..<48, with: le32(1))
    header.replaceSubrange(48..<52, with: le32(0))
    header.replaceSubrange(68..<72, with: le32(0xFFFF_FFFE))

    for index in 0..<109 {
      header.replaceSubrange(
        (76 + index * 4)..<(80 + index * 4), with: le32(index == 0 ? 1 : 0xFFFF_FFFF))
    }

    var directory = [UInt8](repeating: 0, count: 512)

    for (index, name) in streams.prefix(4).enumerated() {
      let units = Array(name.utf16) + [0]
      let base = index * 128

      for (offset, unit) in units.enumerated() {
        directory.replaceSubrange((base + offset * 2)..<(base + offset * 2 + 2), with: le16(unit))
      }

      directory.replaceSubrange((base + 64)..<(base + 66), with: le16(UInt16(units.count * 2)))
      directory[base + 66] = index == 0 ? 5 : 2
    }

    var fat = [UInt8](repeating: 0xFF, count: 512)
    fat.replaceSubrange(0..<4, with: le32(0xFFFF_FFFE))
    fat.replaceSubrange(4..<8, with: le32(0xFFFF_FFFD))

    return header + directory + fat
  }
}
