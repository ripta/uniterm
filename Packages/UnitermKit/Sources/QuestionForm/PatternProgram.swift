import Foundation

/// A compiled `pattern`, ECMA-262's in Unicode mode.
///
/// It is searched unanchored, as JSON Schema does. `NSRegularExpression` runs it, from ICU text
/// that the emitter wrote from the parse tree.
///
/// A search runs for a bounded time. ICU reports progress during a match, and the progress
/// callback stops a runaway match in-process, so a hostile pattern never holds a thread past its
/// limit.
public final class PatternProgram: Equatable, @unchecked Sendable {
  /// The result of one search.
  public enum Outcome: Equatable, Sendable {
    case matched
    case noMatch

    /// The time limit passed. The match stopped.
    case timedOut

    /// The input is longer than a check accepts.
    case inputTooLong

    /// The caller's `shouldStop` asked to stop, since a newer value superseded this one.
    case stopped

    /// ICU gave up before it reached an answer, such as when its backtracking stack ran out.
    /// Reading that as no match would call a valid input wrong.
    case failed
  }

  public let source: String

  private let expression: NSRegularExpression

  /// Parses, translates, and compiles a pattern. A pattern the grammar refuses, or that ICU does
  /// not compile, throws.
  public init(source: String) throws {
    guard source.utf8.count <= FormLimits.maxPatternBytes else {
      throw PatternError("a pattern over \(FormLimits.maxPatternBytes) bytes")
    }

    let tree = try PatternParser.parse(source)
    let text = PatternEmitter.emit(tree)

    do {
      expression = try NSRegularExpression(pattern: text, options: [])
    } catch {
      throw PatternError("a pattern that does not compile")
    }

    self.source = source
  }

  public static func == (lhs: PatternProgram, rhs: PatternProgram) -> Bool {
    lhs.source == rhs.source
  }

  /// Searches `text` for a match, for at most `limit` seconds. This blocks the calling thread, so
  /// the main thread never calls it.
  public func search(
    _ text: String, limit: TimeInterval = FormLimits.patternTimeLimit,
    shouldStop: () -> Bool = { false }
  ) -> Outcome {
    let length = text.utf16.count

    guard length <= FormLimits.maxPatternInputUnits else { return .inputTooLong }

    let started = ProcessInfo.processInfo.systemUptime
    var outcome = Outcome.failed

    expression.enumerateMatches(
      in: text, options: [.reportProgress, .reportCompletion],
      range: NSRange(location: 0, length: length)
    ) { result, flags, stop in
      if flags.contains(.internalError) {
        outcome = .failed
        stop.pointee = true

        return
      }

      if flags.contains(.completed) {
        if outcome == .failed { outcome = .noMatch }

        return
      }

      if flags.contains(.progress) {
        if shouldStop() {
          outcome = .stopped
          stop.pointee = true
        } else if ProcessInfo.processInfo.systemUptime - started > limit {
          outcome = .timedOut
          stop.pointee = true
        }

        return
      }

      if result != nil {
        outcome = .matched
        stop.pointee = true
      }
    }

    return outcome
  }
}
