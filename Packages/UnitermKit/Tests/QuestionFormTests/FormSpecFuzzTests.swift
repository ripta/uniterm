import Foundation
import TableTestSupport
import XCTest

@testable import QuestionForm

/// A seeded mutation fuzzer for the spec reader and the pattern parser. Each input is a valid
/// spec with bytes flipped, cut, or inserted.
///
/// `make test-package` runs it at a small count. `make fuzz` runs it under the address sanitizer
/// at a large one, through `UNITERM_FUZZ_ITERATIONS`. `UNITERM_FUZZ_SEED` repeats a run.
///
/// It proves that no mutated spec or pattern traps the reader, and that an accepted spec always
/// has a result that fits one reply. It cannot prove that a refusal names the right field.
final class FormSpecFuzzTests: XCTestCase {
  private var iterations: Int {
    ProcessInfo.processInfo.environment["UNITERM_FUZZ_ITERATIONS"].flatMap(Int.init) ?? 300
  }

  private var seed: UInt64 {
    ProcessInfo.processInfo.environment["UNITERM_FUZZ_SEED"].flatMap(UInt64.init) ?? 0x22_0001
  }

  private static let seedSpec = """
    {"title": "T", "items": [
      {"block": "notice", "level": "warning", "text": "n"},
      {"block": "table", "rows": {"a": "b"}},
      {"id": "r", "text": "t", "type": "choice", "choices": ["a", "b"], "other": true},
      {"id": "n", "text": "t", "type": "number", "default": 1.5,
       "validate": {"minimum": -1, "multipleOf": 0.1}},
      {"id": "s", "text": "t", "type": "string",
       "validate": {"minLength": 1, "pattern": "^(?:[a-z]+|\\\\d{2,3})\\\\b$"}},
      {"id": "f", "text": "t", "type": "file", "multiple": true, "validate": {"maxItems": 3}}],
     "actions": [{"id": "ok", "role": "primary"}, {"id": "c", "role": "cancel"}]}
    """

  /// Catches a mutated spec that traps the reader, or that is accepted with a result too large for
  /// a reply.
  func testMutatedSpecsReadWithoutTrapping() throws {
    var random = SplitMix64(seed: seed)
    let base = [UInt8](Self.seedSpec.utf8)

    XCTAssertNoThrow(try FormSpecReader.decode(Data(base)))

    for iteration in 0..<iterations {
      var bytes = base

      for _ in 0..<Int(1 + random.next() % 4) { mutate(&bytes, using: &random) }

      guard let spec = try? FormSpecReader.decode(Data(bytes)) else { continue }

      XCTAssertFalse(spec.buttons.isEmpty, "seed \(seed), iteration \(iteration)")
      XCTAssertLessThanOrEqual(spec.questions.count, FormLimits.maxItems)
    }
  }

  /// Catches a mutated pattern that traps the parser or the emitter, or that compiles into ICU
  /// text the parser did not mean.
  func testMutatedPatternsParseWithoutTrapping() throws {
    var random = SplitMix64(seed: seed &+ 1)
    let base = [UInt8](#"^(?:[a-z\d]+|\p{Lu}{2,3}|[^\s&&x])(?=\b).*?\u{1F600}\x41$"#.utf8)

    for _ in 0..<iterations {
      var bytes = base

      for _ in 0..<Int(1 + random.next() % 3) { mutate(&bytes, using: &random) }

      guard let source = String(validating: bytes, as: UTF8.self),
        let program = try? PatternProgram(source: source)
      else { continue }

      _ = program.search("abc DEF 12\n", limit: 0.05)
    }
  }

  private func mutate(_ bytes: inout [UInt8], using random: inout SplitMix64) {
    guard !bytes.isEmpty else { return }

    let at = Int(random.next() % UInt64(bytes.count))

    switch random.next() % 4 {
    case 0: bytes[at] = UInt8(truncatingIfNeeded: random.next())
    case 1: bytes.insert(UInt8(truncatingIfNeeded: random.next()), at: at)
    case 2: bytes.remove(at: at)
    default: bytes = Array(bytes[..<at])
    }
  }
}
