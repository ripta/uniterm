import Foundation

/// `xl/workbook.xml`: the sheets in order, and the date system.
final class WorkbookHandler: XMLHandler {
  struct Sheet {
    var name: String
    var relationshipID: String
    var isHidden: Bool
  }

  private(set) var sheets: [Sheet] = []
  private(set) var date1904 = false
  private let maxSheets: Int

  init(maxSheets: Int) {
    self.maxSheets = maxSheets
  }

  override func begin(_ name: String, _ attributes: [String: String]) {
    switch name {
    case "workbookPr":
      date1904 = ["1", "true"].contains(attributes["date1904"] ?? "")

    case "sheet":
      guard sheets.count < maxSheets else {
        stop(.tooLarge("it names more than \(maxSheets) sheets"))
        return
      }

      // The relationship attribute is `r:id` by convention, but the prefix is the file's choice.
      let relationship = attributes.first { $0.key == "id" || $0.key.hasSuffix(":id") }?.value

      sheets.append(
        Sheet(
          name: String((attributes["name"] ?? "").prefix(255)), relationshipID: relationship ?? "",
          isHidden: ["hidden", "veryHidden"].contains(attributes["state"] ?? "")))

    default:
      break
    }
  }
}

/// A `.rels` part: what each relationship id points at.
final class RelationshipsHandler: XMLHandler {
  struct Relationship {
    /// The last segment of the relationship type, such as `worksheet` or `sharedStrings`.
    var kind: String
    var target: String
  }

  private(set) var relationships: [String: Relationship] = [:]
  private(set) var order: [String] = []
  private let maxRelationships: Int

  init(maxRelationships: Int) {
    self.maxRelationships = maxRelationships
  }

  override func begin(_ name: String, _ attributes: [String: String]) {
    guard name == "Relationship", attributes["TargetMode"] != "External" else { return }

    guard relationships.count < maxRelationships else {
      stop(.tooLarge("it names more than \(maxRelationships) relationships"))
      return
    }

    let id = attributes["Id"] ?? ""
    let kind = (attributes["Type"] ?? "").split(separator: "/").last.map(String.init) ?? ""

    if relationships[id] == nil { order.append(id) }

    relationships[id] = Relationship(kind: kind, target: attributes["Target"] ?? "")
  }

  /// The first relationship of a kind, in file order.
  func first(kind: String) -> Relationship? {
    order.lazy.compactMap { self.relationships[$0] }.first { $0.kind == kind }
  }
}

/// `xl/styles.xml`: which cell styles show numbers as dates.
final class StylesHandler: XMLHandler {
  private var codes: [Int: String] = [:]
  private var formatIDs: [Int] = []
  private var inNumberFormats = false
  private var inCellFormats = false
  private let maxStyles: Int

  init(maxStyles: Int) {
    self.maxStyles = maxStyles
  }

  override func begin(_ name: String, _ attributes: [String: String]) {
    switch name {
    case "numFmts":
      inNumberFormats = true

    case "numFmt" where inNumberFormats:
      if let id = Int(attributes["numFmtId"] ?? ""), codes.count < maxStyles {
        codes[id] = attributes["formatCode"] ?? ""
      }

    case "cellXfs":
      inCellFormats = true

    case "xf" where inCellFormats:
      guard formatIDs.count < maxStyles else {
        stop(.tooLarge("its styles part defines more than \(maxStyles) cell styles"))
        return
      }

      formatIDs.append(Int(attributes["numFmtId"] ?? "") ?? 0)

    default:
      break
    }
  }

  override func end(_ name: String) {
    switch name {
    case "numFmts": inNumberFormats = false
    case "cellXfs": inCellFormats = false
    default: break
    }
  }

  /// The number style of each cell style, by its index.
  func styles() -> [NumberStyle] {
    var classified: [Int: NumberStyle] = [:]

    return formatIDs.map { id in
      if let known = classified[id] { return known }

      let style = codes[id].map(SpreadsheetDates.classify) ?? SpreadsheetDates.builtIn(id)
      classified[id] = style
      return style
    }
  }
}

/// The shared strings table: every string once, in one byte buffer with an end offset for each.
struct SharedStrings: Sendable {
  var bytes: [UInt8] = []
  var ends: [UInt32] = []

  /// The strings that a size cap cut. A cell that shows one of them is a cut cell.
  var cut: Set<Int> = []

  var count: Int { ends.count }

  /// What the table holds, as memory the load reserves.
  var cost: Int { bytes.count + MemoryLayout<UInt32>.stride * ends.count }

  func string(at index: Int) -> ArraySlice<UInt8>? {
    guard index >= 0, index < ends.count else { return nil }

    let start = index == 0 ? 0 : Int(ends[index - 1])
    return bytes[start..<Int(ends[index])]
  }
}

/// `xl/sharedStrings.xml`. A string is the text of its `<t>` runs. Phonetic runs are hints for
/// reading, not text, so they are left out.
final class SharedStringsHandler: XMLHandler {
  private(set) var table = SharedStrings()
  private(set) var reserved = 0

  private let cellBytes: Int
  private let reserve: (Int) -> TableBudget.Reservation
  private var inItem = false
  private var inText = false
  private var phonetic = 0
  private var current: [UInt8] = []
  private var currentIsCut = false

  /// `reserve` asks the memory budget for bytes and returns its answer.
  init(cellBytes: Int, reserve: @escaping (Int) -> TableBudget.Reservation) {
    self.cellBytes = cellBytes
    self.reserve = reserve
  }

  override func begin(_ name: String, _ attributes: [String: String]) {
    switch name {
    case "si":
      inItem = true
      current.removeAll(keepingCapacity: true)
      currentIsCut = false

    case "rPh":
      phonetic += 1

    case "t" where inItem && phonetic == 0:
      inText = true

    default:
      break
    }
  }

  override func end(_ name: String) {
    switch name {
    case "t":
      inText = false

    case "rPh":
      phonetic = max(0, phonetic - 1)

    case "si":
      inItem = false
      table.bytes.append(contentsOf: SpreadsheetText.unescape(current))
      table.ends.append(UInt32(truncatingIfNeeded: table.bytes.count))

      if currentIsCut { table.cut.insert(table.count - 1) }

      // The reservation runs ahead of the table in 1 MiB steps, so the budget is asked rarely.
      if table.cost > reserved {
        let step = table.cost - reserved + (1 << 20)

        let answer = reserve(step)

        guard answer == .granted else {
          stop(.refused(answer))
          return
        }

        reserved += step
      }

    default:
      break
    }
  }

  override func text(_ characters: String) {
    guard inText else { return }

    if SpreadsheetText.append(characters, to: &current, cap: cellBytes) { currentIsCut = true }
  }
}

enum SpreadsheetText {
  /// Appends `text` up to `cap` bytes, cutting at a character. Returns true when it cut.
  static func append(_ text: String, to bytes: inout [UInt8], cap: Int) -> Bool {
    if bytes.count + text.utf8.count <= cap {
      bytes.append(contentsOf: text.utf8)
      return false
    }

    for scalar in text.unicodeScalars {
      let width = UTF8.width(scalar)

      if bytes.count + width > cap { return true }

      bytes.append(contentsOf: String(scalar).utf8)
    }

    return false
  }

  /// Decodes the `_xHHHH_` escapes that Excel writes for characters XML cannot hold. A pair of
  /// surrogate escapes is one character. A lone surrogate becomes U+FFFD.
  static func unescape(_ bytes: [UInt8]) -> [UInt8] {
    guard bytes.contains(UInt8(ascii: "_")) else { return bytes }

    var output: [UInt8] = []
    output.reserveCapacity(bytes.count)

    var index = 0

    func unit(at start: Int) -> UInt16? {
      guard start + 7 <= bytes.count, bytes[start] == 0x5F, bytes[start + 1] == 0x78,
        bytes[start + 6] == 0x5F
      else { return nil }

      var value: UInt16 = 0

      for offset in 2..<6 {
        guard let digit = hex(bytes[start + offset]) else { return nil }

        value = value << 4 | UInt16(digit)
      }

      return value
    }

    func hex(_ byte: UInt8) -> Int? {
      switch byte {
      case 0x30...0x39: return Int(byte) - 0x30
      case 0x41...0x46: return Int(byte) - 0x41 + 10
      case 0x61...0x66: return Int(byte) - 0x61 + 10
      default: return nil
      }
    }

    while index < bytes.count {
      guard let first = unit(at: index) else {
        output.append(bytes[index])
        index += 1
        continue
      }

      index += 7

      var scalar: Unicode.Scalar?

      if (0xD800...0xDBFF).contains(first), let second = unit(at: index),
        (0xDC00...0xDFFF).contains(second)
      {
        index += 7
        scalar = Unicode.Scalar(
          0x10000 + (UInt32(first) - 0xD800) << 10 + (UInt32(second) - 0xDC00))
      } else {
        scalar = Unicode.Scalar(UInt32(first))
      }

      output.append(contentsOf: String(scalar ?? "\u{FFFD}").utf8)
    }

    return output
  }
}
