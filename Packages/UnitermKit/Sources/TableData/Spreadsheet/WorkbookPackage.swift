import Darwin
import Foundation
import ZIPFoundation

/// An `.xlsx` file opened as an OPC package: a ZIP archive whose parts name each other through
/// relationship files.
///
/// The archive is opened through the descriptor the loader already checked, so a path swapped for
/// something else after the check cannot be opened instead.
final class WorkbookPackage {
  struct Sheet {
    var name: String
    var path: String
    var isHidden: Bool
  }

  struct Layout {
    var sheets: [Sheet]
    var date1904: Bool
    var stylesPath: String?
    var sharedStringsPath: String?
  }

  let limits: SpreadsheetLimits
  private let box: ArchiveBox
  private var entries: [String: Entry] = [:]
  private let isCancelled: () -> Bool

  /// Opens the archive. Throws `unsupported` for the files that share a workbook's extension and
  /// are not ZIP archives, and `invalid` for a ZIP archive that does not open.
  init(
    descriptor: Int32, fileSize: Int, limits: SpreadsheetLimits, isCancelled: @escaping () -> Bool
  ) throws {
    self.limits = limits
    self.isCancelled = isCancelled

    var head = [UInt8](repeating: 0, count: 8)
    let count = head.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, 8, 0) }

    if count == 8, head == CompoundFile.signature {
      throw SpreadsheetFailure.unsupported(CompoundFile.classify(descriptor, fileSize: fileSize))
    }

    guard count >= 4, head[0] == 0x50, head[1] == 0x4B else {
      throw SpreadsheetFailure.invalid("it is not a ZIP archive, which every .xlsx file is")
    }

    // ZIPFoundation looks for the end record by stepping back through the whole file one byte at a
    // time. The record sits within the last 64 KiB, so a file without one is refused here first.
    guard Self.hasEndRecord(descriptor, fileSize: fileSize) else {
      throw SpreadsheetFailure.invalid("its ZIP directory is missing")
    }

    let archive: Archive

    do {
      archive = try Archive(
        url: URL(fileURLWithPath: "/dev/fd/\(descriptor)"), accessMode: .read)
    } catch {
      throw SpreadsheetFailure.invalid("its ZIP directory cannot be read")
    }

    box = ArchiveBox(archive)

    var seen = 0

    for entry in archive {
      seen += 1

      if seen > limits.entries {
        throw SpreadsheetFailure.tooLarge("it holds more than \(limits.entries) files")
      }

      if seen & 0xFFF == 0, isCancelled() { throw SpreadsheetFailure.cancelled }

      let key = Self.key(entry.path)

      if entries[key] == nil { entries[key] = entry }
    }
  }

  private static func hasEndRecord(_ descriptor: Int32, fileSize: Int) -> Bool {
    let length = min(fileSize, 65_557)

    guard length >= 22 else { return false }

    var tail = [UInt8](repeating: 0, count: length)
    let count = tail.withUnsafeMutableBytes {
      pread(descriptor, $0.baseAddress, length, off_t(fileSize - length))
    }

    guard count == length else { return false }

    for index in stride(from: length - 22, through: 0, by: -1)
    where tail[index] == 0x50 && tail[index + 1] == 0x4B && tail[index + 2] == 0x05
      && tail[index + 3] == 0x06
    {
      return true
    }

    return false
  }

  /// Part names compare without case, and a leading slash names the same part.
  private static func key(_ path: String) -> String {
    var name = path.lowercased()

    while name.hasPrefix("/") { name.removeFirst() }

    return name
  }

  func entry(_ path: String) -> Entry? {
    entries[Self.key(path)]
  }

  /// Whether any part sits under `prefix`, such as `xl/workbook.bin`.
  func hasPart(prefix: String) -> Bool {
    entries.keys.contains { $0.hasPrefix(prefix) }
  }

  func uncompressedSize(of path: String) -> Int {
    entry(path).map { Int(clamping: $0.uncompressedSize) } ?? 0
  }

  /// The part at `target`, resolved against the folder of the part that names it.
  static func resolve(_ target: String, relativeTo part: String) -> String {
    var segments: [Substring] = []

    if !target.hasPrefix("/") {
      segments = part.split(separator: "/", omittingEmptySubsequences: true).dropLast()
        .map { $0 }
    }

    for segment in target.split(separator: "/", omittingEmptySubsequences: true) {
      if segment == ".." {
        if !segments.isEmpty { segments.removeLast() }
      } else if segment != "." {
        segments.append(segment)
      }
    }

    return segments.joined(separator: "/")
  }

  private func relationshipsPath(of part: String) -> String {
    var segments = part.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    let name = segments.popLast() ?? ""

    return (segments + ["_rels", "\(name).rels"]).joined(separator: "/")
  }

  /// Parses one part, if the package holds it. Returns false when it does not.
  @discardableResult
  func parse(
    _ path: String, cap: Int, what: String, handler: XMLHandler, pump: XMLPump = XMLPump()
  ) throws -> Bool {
    guard let entry = entry(path) else { return false }

    guard entry.type == .file else {
      throw SpreadsheetFailure.invalid("\(path) is not a file in the archive")
    }

    handler.isCancelled = isCancelled
    handler.maxDepth = limits.depth

    try XMLPart.parse(
      entry, in: box, name: path, cap: cap,
      capMessage: "\(what) expanded past \(Self.describe(cap))", limits: limits, pump: pump,
      handler: handler)

    return true
  }

  static func describe(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary)
  }

  /// Finds the workbook, its sheets, and the parts the sheets read from.
  func layout() throws -> Layout {
    var workbookPath = "xl/workbook.xml"

    let root = RelationshipsHandler(maxRelationships: limits.relationships)

    if try parse("_rels/.rels", cap: limits.metadataBytes, what: "its package list", handler: root),
      let document = root.first(kind: "officeDocument")
    {
      workbookPath = Self.resolve(document.target, relativeTo: "")
    }

    if workbookPath.lowercased().hasSuffix(".bin")
      || (entry(workbookPath) == nil && hasPart(prefix: "xl/workbook.bin"))
    {
      throw SpreadsheetFailure.unsupported(.binaryXLSB)
    }

    let workbook = WorkbookHandler(maxSheets: limits.sheets)

    guard
      try parse(
        workbookPath, cap: limits.metadataBytes, what: "its workbook part", handler: workbook)
    else {
      throw SpreadsheetFailure.invalid("the archive holds no Excel workbook")
    }

    guard workbook.rootName == "workbook" else {
      throw SpreadsheetFailure.invalid(
        "the archive holds a \(workbook.rootName ?? "document"), not an Excel workbook")
    }

    let rels = RelationshipsHandler(maxRelationships: limits.relationships)

    try parse(
      relationshipsPath(of: workbookPath), cap: limits.metadataBytes,
      what: "its workbook relationships", handler: rels)

    var sheets: [Sheet] = []
    var names: Set<String> = []

    for sheet in workbook.sheets {
      guard let relationship = rels.relationships[sheet.relationshipID],
        relationship.kind == "worksheet"
      else { continue }

      let path = Self.resolve(relationship.target, relativeTo: workbookPath)

      guard entry(path) != nil else { continue }

      // A name used twice gets a number, so every sheet can be picked and named in the description.
      var name = sheet.name
      var copy = 1

      while !names.insert(name).inserted {
        copy += 1
        name = "\(sheet.name) (\(copy))"
      }

      sheets.append(Sheet(name: name, path: path, isHidden: sheet.isHidden))
    }

    guard !sheets.isEmpty else {
      throw SpreadsheetFailure.invalid("the workbook has no worksheets")
    }

    func path(of kind: String) -> String? {
      rels.first(kind: kind).map { Self.resolve($0.target, relativeTo: workbookPath) }
    }

    return Layout(
      sheets: sheets, date1904: workbook.date1904, stylesPath: path(of: "styles"),
      sharedStringsPath: path(of: "sharedStrings"))
  }
}
