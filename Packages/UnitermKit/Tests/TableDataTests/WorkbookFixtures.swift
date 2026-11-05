import Compression
import Foundation

@testable import TableData

/// Builds ZIP archives and workbooks in code, since the repo holds no binary fixtures.
enum ZipMethod {
  case stored
  case deflate
}

struct ZipPart {
  var name: String
  var data: [UInt8]
  var method = ZipMethod.deflate

  /// The size the directory claims, when a test needs it to lie.
  var claimedSize: UInt32?

  init(_ name: String, _ text: String, method: ZipMethod = .deflate) {
    self.name = name
    data = Array(text.utf8)
    self.method = method
  }

  init(_ name: String, bytes: [UInt8], method: ZipMethod = .deflate, claimedSize: UInt32? = nil) {
    self.name = name
    data = bytes
    self.method = method
    self.claimedSize = claimedSize
  }
}

enum ZipFixture {
  static func archive(_ parts: [ZipPart]) -> [UInt8] {
    var file: [UInt8] = []
    var directory: [UInt8] = []

    for part in parts {
      let name = Array(part.name.utf8)
      var body = part.data
      var method: UInt16 = 0

      if part.method == .deflate, let packed = deflate(part.data) {
        body = packed
        method = 8
      }

      let crc = crc32(part.data)
      let claimed = part.claimedSize ?? UInt32(part.data.count)
      let offset = UInt32(file.count)

      file += le32(0x0403_4B50) + le16(20) + le16(0) + le16(method) + le16(0) + le16(0x21)
      file += le32(crc) + le32(UInt32(body.count)) + le32(claimed) + le16(UInt16(name.count))
      file += le16(0) + name + body

      directory += le32(0x0201_4B50) + le16(20) + le16(20) + le16(0) + le16(method) + le16(0)
      directory += le16(0x21) + le32(crc) + le32(UInt32(body.count)) + le32(claimed)
      directory += le16(UInt16(name.count)) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0)
      directory += le32(offset) + name
    }

    let start = UInt32(file.count)

    return file + directory + le32(0x0605_4B50) + le16(0) + le16(0) + le16(UInt16(parts.count))
      + le16(UInt16(parts.count)) + le32(UInt32(directory.count)) + le32(start) + le16(0)
  }

  /// Reads back an archive that `archive` wrote, so a seed can be taken apart and mutated.
  static func parts(of archive: [UInt8]) -> [ZipPart]? {
    func u16(_ at: Int) -> Int { Int(archive[at]) | Int(archive[at + 1]) << 8 }
    func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }

    guard archive.count >= 22 else { return nil }

    let end = archive.count - 22
    var offset = u32(end + 16)
    var parts: [ZipPart] = []

    for _ in 0..<u16(end + 10) {
      let method = u16(offset + 10)
      let packed = u32(offset + 20)
      let size = u32(offset + 24)
      let nameLength = u16(offset + 28)
      let local = u32(offset + 42)
      let name = String(
        decoding: archive[(offset + 46)..<(offset + 46 + nameLength)], as: UTF8.self)
      let data = local + 30 + u16(local + 26) + u16(local + 28)
      let body = Array(archive[data..<(data + packed)])

      var text = body

      if method == 8 {
        var output = [UInt8](repeating: 0, count: max(size, 1))
        let count = compression_decode_buffer(
          &output, output.count, body, body.count, nil, COMPRESSION_ZLIB)
        text = Array(output[0..<count])
      }

      parts.append(ZipPart(name, bytes: text, method: method == 8 ? .deflate : .stored))
      offset += 46 + nameLength
    }

    return parts
  }

  static func deflate(_ bytes: [UInt8]) -> [UInt8]? {
    guard !bytes.isEmpty else { return nil }

    let capacity = bytes.count + 4_096
    var output = [UInt8](repeating: 0, count: capacity)

    let count = compression_encode_buffer(
      &output, capacity, bytes, bytes.count, nil, COMPRESSION_ZLIB)

    return count > 0 ? Array(output[0..<count]) : nil
  }

  private static let table: [UInt32] = (0..<256).map { index in
    var value = UInt32(index)

    for _ in 0..<8 {
      value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
    }

    return value
  }

  static func crc32(_ bytes: [UInt8]) -> UInt32 {
    var value: UInt32 = 0xFFFF_FFFF

    for byte in bytes {
      value = table[Int((value ^ UInt32(byte)) & 0xFF)] ^ (value >> 8)
    }

    return value ^ 0xFFFF_FFFF
  }

  static func le16(_ value: UInt16) -> [UInt8] {
    [UInt8(value & 0xFF), UInt8(value >> 8)]
  }

  static func le32(_ value: UInt32) -> [UInt8] {
    [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24)]
  }
}

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
