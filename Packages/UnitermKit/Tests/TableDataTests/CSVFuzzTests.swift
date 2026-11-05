import Foundation
import XCTest

@testable import TableData

/// A seeded mutation fuzzer for the CSV stack as shipped: the encoding pick, the transcoder, the
/// delimiter sniffer, the parser, the page store, and the sort and filter over it.
///
/// `make test-package` runs it at a small count. `make fuzz` runs it under the address sanitizer
/// at a large one, through `UNITERM_FUZZ_ITERATIONS`. `UNITERM_FUZZ_SEED` repeats a run. A failure
/// names the seed and the iteration, and writes the input to the test's scratch folder.
///
/// It proves that no mutated input traps, reads out of bounds, or breaks the store's own
/// invariants. It cannot prove the cells are right. The loader and parser tests prove that.
/// ASan does not instrument the system libraries the way it does Swift, so memory errors inside
/// libxml2 or zlib are a later reader's concern.
final class CSVFuzzTests: XCTestCase {
  private var iterations: Int {
    ProcessInfo.processInfo.environment["UNITERM_FUZZ_ITERATIONS"].flatMap(Int.init) ?? 300
  }

  private var seed: UInt64 {
    ProcessInfo.processInfo.environment["UNITERM_FUZZ_SEED"].flatMap(UInt64.init) ?? 0x5EED
  }

  /// Catches an input that makes the loader trap or leaves the store inconsistent.
  func testMutatedFilesLoadWithoutTrappingAndKeepTheStoreConsistent() throws {
    let scratch = try Scratch(self)
    var random = SplitMix64(seed: seed)
    let corpus = Self.corpus()

    for iteration in 0..<iterations {
      var input = corpus[Int(random.next() % UInt64(corpus.count))]

      for _ in 0..<(1 + Int(random.next() % 6)) {
        Self.mutate(&input, using: &random)
      }

      let name = random.next() % 7 == 0 ? "fuzz.tsv" : "fuzz.csv"
      let file = try scratch.write(name, input)
      let context = "seed \(seed), iteration \(iteration), input kept at \(file.path)"

      let pageTarget = [64, 512, 4096, TableLoader.defaultPageTarget][Int(random.next() % 4)]
      let limit = random.next() % 5 == 0 ? 2_000 : 1 << 30
      let loaded = loadFile(
        file, budget: TableBudget(limit: limit, floor: 0), pageTarget: pageTarget)

      switch loaded.end {
      case .completed, .stoppedAtBudget:
        break

      default:
        XCTFail("unexpected end \(loaded.end), \(context)")
        continue
      }

      try Self.check(loaded.snapshot, using: &random, context: context)
    }
  }

  /// Catches a parser whose rows depend on where the reads split. Random splits of mutated input
  /// give the rows of the whole input.
  func testRandomChunkingNeverChangesTheRows() {
    var random = SplitMix64(seed: seed &+ 1)
    let corpus = Self.corpus()

    for iteration in 0..<iterations {
      var input = corpus[Int(random.next() % UInt64(corpus.count))]

      for _ in 0..<(1 + Int(random.next() % 4)) {
        Self.mutate(&input, using: &random)
      }

      func rows(chunked: Bool, using random: inout SplitMix64) -> [[UInt8]] {
        var parser = CSVParser(delimiter: UInt8(ascii: ","))
        var rows: [[UInt8]] = []

        let sink: CSVParser.Sink = { row, ends in
          rows.append(row + ends.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8 & 0xFF)] })
          return true
        }

        var offset = 0
        while offset < input.count {
          let size = chunked ? 1 + Int(random.next() % 64) : input.count
          parser.feed(input[offset..<min(offset + size, input.count)], sink: sink)
          offset += size
        }

        parser.finish(sink: sink)
        return rows
      }

      let whole = rows(chunked: false, using: &random)
      let split = rows(chunked: true, using: &random)

      XCTAssertEqual(whole, split, "seed \(seed &+ 1), iteration \(iteration)")
    }
  }

  // MARK: Invariants

  private static func check(
    _ snapshot: TableSnapshot, using random: inout SplitMix64, context: String
  ) throws {
    var cells = 0

    for row in 0..<snapshot.rowCount {
      for column in 0..<snapshot.columns.count {
        cells += snapshot.cell(row: row, column: column).count
        _ = snapshot.text(row: row, column: column, limit: 16)
      }
    }

    XCTAssertEqual(snapshot.cell(row: snapshot.rowCount, column: 0).count, 0, context)

    let sampled = (0..<min(snapshot.columns.count, 6)).map { _ in
      snapshot.columns[Int(random.next() % UInt64(snapshot.columns.count))]
    }

    for column in sampled {
      for ascending in [true, false] {
        let query = TableQuery(sort: SortSpec(column: column.identity, ascending: ascending))

        guard case .rows(let rows)? = TableQueryEngine.evaluate(snapshot, query: query) else {
          XCTAssertEqual(snapshot.rowCount, 0, context)
          continue
        }

        XCTAssertEqual(rows.map(Int.init).sorted(), Array(0..<snapshot.rowCount), context)
      }
    }

    let needle = String(
      decoding: (0..<(1 + Int(random.next() % 2))).map { _ in
        UInt8(truncatingIfNeeded: 0x61 + random.next() % 6)
      }, as: UTF8.self)

    let selection = TableQueryEngine.evaluate(snapshot, query: TableQuery(filter: needle))

    for index in 0..<(selection?.count ?? 0) {
      let row = selection?.row(at: index) ?? 0
      let found = (0..<snapshot.columns.count).contains {
        snapshot.text(row: row, column: $0, limit: .max).lowercased().range(of: needle) != nil
      }

      XCTAssertTrue(found, "row \(row) does not hold \(needle), \(context)")
    }
  }

  // MARK: Corpus

  /// The seeds, written out in code since the repo holds no binary fixtures.
  private static func corpus() -> [[UInt8]] {
    let plain = "id,name,amount\n1,widget,9.50\n2,gadget,12\n3,gizmo,\n"
    let quoted = "a,b\n\"x,y\",\"line1\nline2\"\n\"say \"\"hi\"\"\",\"\"\n"
    let semicolons = "k;v\n1;one\n2;two\n"
    let tabs = "k\tv\n1\tone\n2\ttwo\n"
    let crlf = "h1,h2\r\n1,2\r\n\r\n3,4\r\n"
    let accents = "name,city\ncaf\u{E9},Z\u{FC}rich\n\u{20AC}5,\u{1F600}\n"

    let utf16 =
      [0xFF, 0xFE] as [UInt8]
      + accents.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
    let cp1252: [UInt8] = Array("name,price\ncaf".utf8) + [0xE9, 0x2C, 0x80, 0x35, 0x0A]
    let manyColumns = [UInt8](repeating: UInt8(ascii: ","), count: 70_000) + [0x0A]

    return [
      Array(plain.utf8), Array(quoted.utf8), Array(semicolons.utf8), Array(tabs.utf8),
      Array(crlf.utf8), [0xEF, 0xBB, 0xBF] + Array(accents.utf8), utf16, cp1252,
      Array("\"unterminated,quote\n1,2".utf8), Array("a,b\n1,2".utf8), [], [0x0A], manyColumns,
      [UInt8](repeating: UInt8(ascii: "\""), count: 33),
    ]
  }

  private static let interesting: [UInt8] = [
    0x2C, 0x22, 0x0D, 0x0A, 0x00, 0xFF, 0xC3, 0xE2, 0x80, 0x09, 0x3B, 0x7C, 0xFE, 0xEF, 0xBB, 0xBF,
    0xF0, 0x9F, 0xD8, 0xDC,
  ]

  private static func mutate(_ input: inout [UInt8], using random: inout SplitMix64) {
    let size = input.count

    switch random.next() % 8 {
    case 0 where size > 0:
      input[Int(random.next() % UInt64(size))] ^= UInt8(1 << (random.next() % 8))

    case 1 where size > 0:
      input[Int(random.next() % UInt64(size))] =
        interesting[Int(random.next() % UInt64(interesting.count))]

    case 2:
      let at = Int(random.next() % UInt64(size + 1))
      let bytes = (0..<(1 + Int(random.next() % 8))).map { _ in
        interesting[Int(random.next() % UInt64(interesting.count))]
      }
      input.insert(contentsOf: bytes, at: at)

    case 3 where size > 0:
      let start = Int(random.next() % UInt64(size))
      let end = min(size, start + 1 + Int(random.next() % 16))
      input.removeSubrange(start..<end)

    case 4 where size > 0:
      let start = Int(random.next() % UInt64(size))
      let end = min(size, start + 1 + Int(random.next() % 64))
      input.insert(contentsOf: Array(input[start..<end]), at: end)

    case 5 where size > 0:
      input.removeLast(Int(random.next() % UInt64(size)))

    case 6:
      input.insert(
        contentsOf: [[0xEF, 0xBB, 0xBF], [0xFF, 0xFE], [0xFE, 0xFF]][Int(random.next() % 3)], at: 0)

    default:
      input.append(
        contentsOf: [UInt8](repeating: UInt8(ascii: "\""), count: Int(random.next() % 5)))
    }
  }
}

/// A small, seedable generator, so a failing run repeats from its seed.
struct SplitMix64: RandomNumberGenerator {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15

    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}
