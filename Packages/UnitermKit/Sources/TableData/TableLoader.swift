import Darwin
import Foundation

/// Where a table's rows come from. A file is the only source today. A byte stream joins when its
/// first caller lands, and spools to a file for the formats that need random access.
public enum TableSource: Sendable, Equatable {
  case file(URL)
}

/// How far a load has come.
public struct LoadProgress: Sendable, Equatable {
  public var bytesRead = 0
  public var totalBytes = 0

  /// Rows that a size cap cut short. See `CSVParser`.
  public var truncatedRows = 0

  public var fraction: Double? {
    totalBytes > 0 ? min(1, Double(bytesRead) / Double(totalBytes)) : nil
  }
}

/// Why a load ended.
public enum LoadEnd: Sendable, Equatable {
  case completed

  /// The memory budget ran out. The snapshot holds the first rows of the file.
  case stoppedAtBudget

  /// The system warned about memory. The snapshot holds the first rows of the file.
  case stoppedLowMemory

  case failed(TableLoadError)
  case cancelled
}

public enum LoadEvent: Sendable {
  case snapshot(TableSnapshot, LoadProgress)
  case finished(TableSnapshot, LoadEnd, LoadProgress)
}

/// Reads a source into a snapshot of rows, off the main thread, under a memory budget.
///
/// The loader opens regular files only. A FIFO, a device, or a socket is refused after the open and
/// before any read, and the open itself never blocks, so a stalled path cannot hold a pane. The
/// rows go into pages of about `pageTarget` bytes. Each page reserves its cost from the lease when
/// it seals. A page the budget refuses is dropped, and the load ends with the pages before it.
public enum TableLoader {
  /// The size at which the row page being filled seals.
  public static let defaultPageTarget = 1 << 20

  /// The least time between two snapshots of a running load.
  static let snapshotInterval = Duration.milliseconds(100)

  @concurrent
  public static func load(
    _ source: TableSource, lease: TableBudget.Lease, pageTarget: Int = defaultPageTarget,
    emit: @escaping @Sendable (LoadEvent) -> Void
  ) async {
    loadBlocking(
      source, lease: lease, pageTarget: pageTarget, isCancelled: { Task.isCancelled }, emit: emit)
  }

  /// The same load on the calling thread. Tests and the fuzzer call it directly.
  public static func loadBlocking(
    _ source: TableSource, lease: TableBudget.Lease, pageTarget: Int = defaultPageTarget,
    isCancelled: @escaping () -> Bool = { false }, emit: @escaping (LoadEvent) -> Void
  ) {
    var run = LoadRun(lease: lease, pageTarget: pageTarget, isCancelled: isCancelled, emit: emit)

    switch source {
    case .file(let url):
      run.load(file: url)
    }
  }
}

private struct LoadRun {
  let lease: TableBudget.Lease
  let pageTarget: Int
  let isCancelled: () -> Bool
  let emit: (LoadEvent) -> Void

  private var pages: [RowPage] = []
  private var builder = RowPageBuilder()
  private var header: [String]?
  private var maxCells = 0
  private var firstRow = true
  private var progress = LoadProgress()
  private var end: LoadEnd?
  private var lastSnapshot = ContinuousClock.now

  init(
    lease: TableBudget.Lease, pageTarget: Int, isCancelled: @escaping () -> Bool,
    emit: @escaping (LoadEvent) -> Void
  ) {
    self.lease = lease
    self.pageTarget = pageTarget
    self.isCancelled = isCancelled
    self.emit = emit
  }

  mutating func load(file url: URL) {
    let path = url.path
    let ext = url.pathExtension.lowercased()

    let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)

    guard descriptor >= 0 else {
      finish(.failed(.posix(errno, path: path)))
      return
    }

    defer { close(descriptor) }

    var info = stat()

    guard fstat(descriptor, &info) == 0 else {
      finish(.failed(.posix(errno, path: path)))
      return
    }

    guard info.st_mode & S_IFMT == S_IFREG else {
      finish(.failed(.notARegularFile(path: path, kind: Self.kind(of: info.st_mode))))
      return
    }

    switch Format.of(extension: ext) {
    case .unsupported(let description, let comingLater):
      finish(
        .failed(.unsupportedFormat(path: path, description: description, comingLater: comingLater)))
      return

    case .csv:
      break
    }

    progress.totalBytes = Int(info.st_size)
    readCSV(from: descriptor, fileExtension: ext, path: path)
  }

  private mutating func readCSV(from descriptor: Int32, fileExtension: String, path: String) {
    var chunk = [UInt8](repeating: 0, count: 256 << 10)
    var sample: [UInt8] = []
    var atEnd = false

    while sample.count < CSVRule.sampleSize, !atEnd {
      guard let count = fill(descriptor, &chunk, into: &sample, path: path) else { return }

      atEnd = count == 0
    }

    let head = Array(sample.prefix(CSVRule.sampleSize))
    let (encoding, bom) = CSVRule.encoding(
      of: head, isWholeFile: atEnd && head.count == sample.count)

    var sniffed: [UInt8] = []
    var sniffer = TextTranscoder(encoding)
    sniffer.convert(head[bom...], final: false, into: &sniffed)

    var transcoder = TextTranscoder(encoding)
    var text: [UInt8] = []
    transcoder.convert(sample[bom...], final: atEnd, into: &text)

    var parser = CSVParser(
      delimiter: CSVRule.delimiter(in: sniffed, fileExtension: fileExtension))

    feed(&parser, text[...], final: atEnd)

    var raw: [UInt8] = []

    while !atEnd, end == nil {
      if isCancelled() {
        finish(.cancelled)
        return
      }

      raw.removeAll(keepingCapacity: true)

      guard let count = fill(descriptor, &chunk, into: &raw, path: path) else { return }

      atEnd = count == 0
      text.removeAll(keepingCapacity: true)
      transcoder.convert(raw[...], final: atEnd, into: &text)
      feed(&parser, text[...], final: atEnd)
    }

    guard end == nil else { return }

    progress.truncatedRows = parser.truncatedRows

    if !sealPage() { return }

    finish(.completed)
  }

  /// Reads one chunk and appends it to `bytes`. Returns the count, or nil after the load has ended
  /// with the read's error.
  private mutating func fill(
    _ descriptor: Int32, _ chunk: inout [UInt8], into bytes: inout [UInt8], path: String
  ) -> Int? {
    while true {
      let count = chunk.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }

      if count < 0 {
        if errno == EINTR { continue }

        finish(.failed(.posix(errno, path: path)))
        return nil
      }

      bytes.append(contentsOf: chunk[0..<count])
      progress.bytesRead += count
      return count
    }
  }

  private mutating func feed(_ parser: inout CSVParser, _ text: ArraySlice<UInt8>, final: Bool) {
    guard end == nil else { return }

    parser.feed(text) { row, ends in
      accept(row: row, ends: ends)
      return end == nil
    }

    if final, end == nil {
      parser.finish { row, ends in
        accept(row: row, ends: ends)
        return end == nil
      }
    }

    progress.truncatedRows = parser.truncatedRows
    publishIfDue()
  }

  private mutating func accept(row: [UInt8], ends: [UInt32]) {
    if firstRow {
      firstRow = false
      var start = 0
      var cells: [String] = []

      for cellEnd in ends {
        cells.append(String(decoding: row[start..<Int(cellEnd)], as: UTF8.self))
        start = Int(cellEnd)
      }

      maxCells = max(maxCells, cells.count)

      if CSVRule.isHeader(cells) {
        header = cells
        return
      }
    }

    maxCells = max(maxCells, ends.count)
    builder.append(row: row, ends: ends)

    if builder.cost >= pageTarget {
      _ = sealPage()
    }
  }

  /// Moves the page being filled into the sealed pages, if the budget lets it. Returns false after
  /// the load ended because it did not.
  private mutating func sealPage() -> Bool {
    guard builder.rowCount > 0 else { return true }

    let page = builder.sealed()

    switch lease.reserve(page.cost) {
    case .granted:
      pages.append(page)
      builder.reset()
      return true

    case .overBudget:
      finish(.stoppedAtBudget)
      return false

    case .memoryPressure:
      finish(.stoppedLowMemory)
      return false

    case .released:
      finish(.cancelled)
      return false
    }
  }

  private func snapshot(includingPartialPage: Bool) -> TableSnapshot {
    var all = pages

    if includingPartialPage, builder.rowCount > 0 {
      all.append(builder.sealed())
    }

    let count = max(maxCells, header?.count ?? 0)
    return TableSnapshot(columns: TableColumn.columns(header: header, count: count), pages: all)
  }

  private mutating func publishIfDue() {
    guard end == nil else { return }

    let now = ContinuousClock.now

    guard now - lastSnapshot >= TableLoader.snapshotInterval else { return }

    lastSnapshot = now
    emit(.snapshot(snapshot(includingPartialPage: true), progress))
  }

  /// Ends the load. A load that stopped early still reports the rows it holds.
  private mutating func finish(_ reason: LoadEnd) {
    guard end == nil else { return }

    end = reason

    switch reason {
    case .failed, .cancelled:
      emit(.finished(.empty, reason, progress))

    case .completed:
      emit(.finished(snapshot(includingPartialPage: false), reason, progress))

    case .stoppedAtBudget, .stoppedLowMemory:
      emit(.finished(snapshot(includingPartialPage: false), reason, progress))
    }
  }

  private static func kind(of mode: mode_t) -> String {
    switch mode & S_IFMT {
    case S_IFDIR: return "a folder"
    case S_IFIFO: return "a pipe"
    case S_IFCHR, S_IFBLK: return "a device"
    case S_IFSOCK: return "a socket"
    default: return "not a regular file"
    }
  }
}

private enum Format {
  case csv
  case unsupported(description: String, comingLater: Bool)

  /// The format a file name's extension names. Only CSV and TSV load today. A format that a later
  /// reader will take says so, and the rest say that the viewer does not read them.
  static func of(extension ext: String) -> Format {
    switch ext {
    case "csv", "tsv", "tab":
      return .csv

    case "json", "jsonl", "ndjson", "geojson":
      return .unsupported(description: "a JSON file", comingLater: true)

    case "xlsx", "xlsm":
      return .unsupported(description: "a spreadsheet", comingLater: true)

    case "":
      return .unsupported(description: "a file with no extension", comingLater: false)

    default:
      return .unsupported(description: "a .\(ext) file", comingLater: false)
    }
  }
}
