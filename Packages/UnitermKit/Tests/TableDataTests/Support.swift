import Foundation
import XCTest

@testable import TableData

/// A scratch folder that a test fills with files. It goes away with the test.
final class Scratch {
  let url: URL

  init(_ test: XCTestCase) throws {
    url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("uniterm-table-\(UUID().uuidString)", isDirectory: true)
      .resolvingSymlinksInPath()

    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

    let folder = url
    test.addTeardownBlock {
      try? FileManager.default.removeItem(at: folder)
    }
  }

  @discardableResult
  func write(_ name: String, _ bytes: [UInt8]) throws -> URL {
    let file = url.appendingPathComponent(name)
    try Data(bytes).write(to: file)
    return file
  }

  @discardableResult
  func write(_ name: String, _ text: String) throws -> URL {
    try write(name, Array(text.utf8))
  }
}

final class EventLog: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [LoadEvent] = []

  func add(_ event: LoadEvent) {
    lock.withLock { stored.append(event) }
  }

  var events: [LoadEvent] { lock.withLock { stored } }
}

struct Loaded {
  let snapshot: TableSnapshot
  let end: LoadEnd
  let progress: LoadProgress
  let events: [LoadEvent]

  /// Every row as text, for comparing against a hand-written table.
  var rows: [[String]] {
    (0..<snapshot.rowCount).map { row in
      (0..<snapshot.columns.count).map { snapshot.text(row: row, column: $0) }
    }
  }

  var titles: [String] { snapshot.columns.map(\.title) }

  /// The index of the column with this title. Fails the test when there is none.
  func column(_ title: String, file: StaticString = #filePath, line: UInt = #line) -> Int {
    guard let index = snapshot.columns.firstIndex(where: { $0.title == title }) else {
      XCTFail("no column titled \(title) in \(titles)", file: file, line: line)
      return 0
    }

    return index
  }

  func text(_ row: Int, _ title: String) -> String {
    snapshot.text(row: row, column: column(title))
  }

  func kind(_ row: Int, _ title: String) -> CellKind {
    snapshot.kind(row: row, column: column(title))
  }
}

/// Loads a file on the calling thread, as the loader runs it, and returns the last event.
func loadFile(
  _ file: URL, budget: TableBudget = TableBudget(limit: 1 << 30, floor: 1 << 20),
  pageTarget: Int = TableLoader.defaultPageTarget, isCancelled: @escaping () -> Bool = { false }
) -> Loaded {
  loadSource(.file(file), budget: budget, pageTarget: pageTarget, isCancelled: isCancelled)
}

/// Loads a nested value the way a nested cell does.
func loadEmbedded(_ json: String) -> Loaded {
  loadSource(.embeddedJSON(name: "cell", bytes: Array(json.utf8)))
}

func loadSource(
  _ source: TableSource, budget: TableBudget = TableBudget(limit: 1 << 30, floor: 1 << 20),
  pageTarget: Int = TableLoader.defaultPageTarget, isCancelled: @escaping () -> Bool = { false }
) -> Loaded {
  let log = EventLog()
  let lease = budget.makeLease()

  TableLoader.loadBlocking(
    source, lease: lease, pageTarget: pageTarget, isCancelled: isCancelled, emit: log.add)

  guard case .finished(let snapshot, let end, let progress)? = log.events.last else {
    fatalError("a load must end with a finished event")
  }

  return Loaded(snapshot: snapshot, end: end, progress: progress, events: log.events)
}
