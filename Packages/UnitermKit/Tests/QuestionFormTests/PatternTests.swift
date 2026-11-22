import Foundation
import JavaScriptCore
import XCTest

@testable import QuestionForm

/// Proves the `pattern` dialect: the translated patterns match as ECMA-262 in Unicode mode does,
/// as JavaScriptCore says. A refusal names the construct, and a match stops at its time limit.
/// JavaScriptCore knows the Unicode version of the system, and ICU knows its own, so a property
/// test samples characters both versions agree on.
final class PatternTests: XCTestCase {
  private func jsMatch(_ pattern: String, _ input: String) -> Bool {
    let context = JSContext()!

    context.setObject(pattern, forKeyedSubscript: "p" as NSString)
    context.setObject(input, forKeyedSubscript: "s" as NSString)

    return context.evaluateScript("new RegExp(p, 'u').test(s)")!.toBool()
  }

  /// Catches a token whose ICU meaning differs from ECMA-262's. Each row names the divergence it
  /// pins, and every row runs against the real JavaScriptCore.
  func testTranslatedPatternsMatchJavaScriptCore() throws {
    let cases: [(String, String)] = [
      (#"^\d+$"#, "123"), (#"^\d+$"#, "\u{0663}\u{0662}"), (#"\d"#, "\u{FF11}"),
      (#"^[a-z]+$"#, "abc\n"), (#"^[a-z]+$"#, "abc"), (#"abc$"#, "abc\n"), (#"abc$"#, "abc\r"),
      (#"^a$"#, "a\u{2028}"),
      (#"^.$"#, "\u{85}"), (#"^.$"#, "\n"), (#"^.$"#, "\u{2028}"), (#"^.$"#, "\u{1F600}"),
      (#"^.$"#, "\r"), (#"^.$"#, "x"), (#"^..$"#, "\u{1F600}"),
      (#"^\w+$"#, "caf\u{E9}"), (#"^\w+$"#, "cafe_9"), (#"\W"#, "\u{E9}"),
      (#"^\s$"#, "\u{FEFF}"), (#"^\s$"#, "\u{A0}"), (#"^\s$"#, "\u{200B}"), (#"^\s$"#, "\u{2003}"),
      (#"^\s$"#, "\u{2028}"), (#"^\s$"#, "\u{85}"), (#"^\S$"#, "\u{85}"), (#"^\s$"#, "\u{180E}"),
      (#"[a&&b]"#, "&"), (#"[a&&b]"#, "a"), (#"^[a&&b]+$"#, "ab&"),
      (#"[a[b]"#, "["), (#"[a-]"#, "-"),
      (#"\bfoo\b"#, "a foo b"), (#"\bfoo\b"#, "afoob"), (#"\bé"#, "é"), (#"\Bé"#, "é"),
      (#"\bcaf\b"#, "caf\u{E9}"), (#"a\B"#, "ab"),
      (#"^[\d]+$"#, "\u{0663}"), (#"^[\D]+$"#, "abc"), (#"^[^\D]+$"#, "123"), (#"^[\D\d]$"#, "x"),
      (#"^[^\W]+$"#, "a_1"), (#"^[\W]$"#, "-"), (#"^[\S]$"#, " "), (#"^[^\S]$"#, " "),
      (#"[\b]"#, "\u{8}"), (#"[]"#, "a"), (#"^[^]$"#, "\n"), (#"[^]"#, ""),
      (#"^(?:a|b)+$"#, "abba"), (#"^(a|)$"#, ""), (#"^()$"#, ""), (#"^(?:)$"#, ""),
      (#"a{2,3}"#, "a"), (#"^a{2,3}$"#, "aaa"), (#"^a{2,}$"#, "aaaa"), (#"^a{2}$"#, "aaa"),
      (#"a+?b"#, "aab"), (#"^(?=a)a"#, "a"), (#"^(?!a)b"#, "b"), (#"^(?!a)b"#, "a"),
      (#"\x41"#, "A"), (#"\u0041"#, "A"), (#"\u{1F600}"#, "\u{1F600}"),
      (#"\uD83D\uDE00"#, "\u{1F600}"),
      (#"^\u{1F600}+$"#, "\u{1F600}\u{1F600}"), (#"\cJ"#, "\n"), (#"\0"#, "\0"),
      (#"\t\n\v\f\r"#, "\t\n\u{B}\u{C}\r"),
      (#"^\/$"#, "/"), (#"\$"#, "$"), (#"\."#, "a"), (#"\."#, "."), (#"\(\)"#, "()"),
      (#"^a|b$"#, "xb"),
      (#"(?<year>\d{4})"#, "2026"), (#"ab"#, "xxabxx"), (#"^$"#, ""), (#""#, "anything"),
      (#"é"#, "e\u{301}"), (#"^.$"#, "e\u{301}"), (#"^e$"#, "e\u{301}"),
      (#"^\p{Lu}+$"#, "ABC"), (#"^\p{Lu}+$"#, "AbC"), (#"^\P{L}+$"#, "123"),
      (#"\p{Script=Greek}"#, "\u{3B1}"),
      (#"\p{sc=Latn}"#, "\u{3B1}"), (#"^\p{Letter}+$"#, "caf\u{E9}"), (#"^[\p{Nd}\-]+$"#, "12-3"),
      (#"\p{Emoji_Presentation}"#, "\u{1F600}"), (#"\p{ASCII}"#, "\u{E9}"),
      (#"^\p{Any}$"#, "\u{1F600}"),
      (#"^\p{Alphabetic}+$"#, "caf\u{E9}"), (#"^[\p{L}\p{N}_]+$"#, "caf\u{E9}_1"),
    ]

    for (pattern, input) in cases {
      guard let program = try? PatternProgram(source: pattern) else {
        XCTFail("refused: \(pattern)")

        continue
      }

      let expected = jsMatch(pattern, input)
      let actual = program.search(input)

      XCTAssertEqual(
        actual, expected ? .matched : .noMatch,
        "/\(pattern)/u on \(input.debugDescription)")
    }
  }

  /// Catches an ICU property spelling that does not compile, or that disagrees with JavaScriptCore,
  /// for every property name the table accepts.
  func testEveryAcceptedPropertyCompilesAndAgrees() throws {
    for name in PatternProperties.emitted {
      XCTAssertNoThrow(try NSRegularExpression(pattern: "\\p{\(name)}"), name)
    }

    let sample = "aZ5_ \u{E9}\u{3B1}\u{4E2D}\u{1F600}\u{301}-!\u{20AC}\n\u{3042}"
    let names = [
      "L", "Lu", "Ll", "N", "Nd", "P", "S", "Z", "Zs", "M", "Mn", "C", "Cc", "Letter", "Alphabetic",
      "Uppercase", "Lowercase", "White_Space", "Emoji", "ASCII", "Any", "Assigned", "ID_Start",
      "Script=Latin", "Script=Greek", "sc=Hira", "scx=Han", "gc=Lu", "General_Category=Letter",
    ]

    for name in names {
      for scalar in sample.unicodeScalars {
        let text = String(scalar)
        let pattern = "^\\p{\(name)}$"
        let program = try PatternProgram(source: pattern)

        XCTAssertEqual(
          program.search(text) == .matched, jsMatch(pattern, text),
          "\(pattern) on U+\(String(scalar.value, radix: 16))")
      }
    }
  }

  /// Catches a construct that reaches ICU with a meaning ECMA-262 does not give it, by naming each
  /// refusal.
  func testRefusalsNameTheConstruct() {
    let cases: [(String, String)] = [
      (#"(a)\1"#, "backreference"), (#"\1"#, "backreference"),
      (#"(?<n>a)\k<n>"#, "named backreference"),
      (#"(?<=a)b"#, "lookbehind"), (#"(?<!a)b"#, "lookbehind"),
      (#"\p{Foo}"#, "not in the supported table"),
      (#"\p{Script=Klingon}"#, "not in the supported table"),
      (#"\p{Lu=1}"#, "not in the supported table"), (#"\p{}"#, "not in the supported table"),
      (#"\pL"#, "without a name"), (#"\P{Bogus}"#, "not in the supported table"),
      (#"\p{ID_Compat_Math_Start}"#, "not in the supported table"),
      (#"\uD83D"#, "lone surrogate"), (#"\uDE00"#, "lone surrogate"),
      (#"a**"#, "nothing to repeat"), (#"*a"#, "nothing to repeat"), (#"a*+"#, "nothing to repeat"),
      (#"^*"#, "nothing to repeat"), (#"(?=a)*"#, "lookahead"),
      (#"a{"#, "quantifier"), (#"a{1"#, "quantifier"), (#"{"#, "unescaped"), (#"}"#, "unescaped"),
      (#"]"#, "unescaped"),
      (#"a{3,2}"#, "maximum is below"), (#"a{1001}"#, "repeat count"),
      (#"(a"#, "never closes"), (#"a)"#, "unmatched"), (#"["#, "never closes"),
      (#"[a-]]"#, "unescaped"),
      (#"\"#, "backslash"), (#"\a"#, "refuses"), (#"\-"#, "refuses"), (#"\e"#, "refuses"),
      (#"\01"#, "octal"),
      (#"\c"#, "control"), (#"\x4"#, "\\x"), (#"\u12"#, "\\u"), (#"\u{110000}"#, "U+10FFFF"),
      (#"[\d-z]"#, "class escape"), (#"[z-a]"#, "out of order"), (#"[\B]"#, "\\B"),
      (#"[\1]"#, "decimal"),
      (#"(?i)a"#, "(?"), (#"(?<n>a)(?<n>b)"#, "twice"), (#"(?<1>a)"#, "identifier"),
    ]

    for (pattern, fragment) in cases {
      XCTAssertThrowsError(try PatternProgram(source: pattern), pattern) {
        XCTAssertTrue(
          ($0 as? PatternError)?.reason.contains(fragment) ?? false, "\(pattern): \($0)")
      }
    }
  }

  func testRefusalsInASpecNameTheFieldAndConstruct() {
    let error = refusal(
      #"{"items": [{"block": "paragraph", "text": "p"}, {"id": "a", "text": "t", "type": "string", "validate": {"pattern": "(a)\\1"}}]}"#
    )

    XCTAssertEqual(error?.field, "items[1].validate.pattern")
    XCTAssertTrue(error?.reason.contains("backreference") ?? false)
  }

  /// Catches a pattern that parses but that ICU cannot compile, such as a nesting past its limits.
  func testPatternSizeAndDepthAreCapped() {
    XCTAssertThrowsError(
      try PatternProgram(
        source: String(repeating: "(", count: 20) + String(repeating: ")", count: 20)))
    XCTAssertThrowsError(try PatternProgram(source: String(repeating: "a?", count: 2100)))
  }

  /// Catches a catastrophic pattern that holds a thread, and one that keeps using CPU after its
  /// check reports. The test sleeps in real time, since the CPU of the stopped match is the claim.
  func testACatastrophicPatternStopsAtItsLimitAndStopsUsingCPU() throws {
    let program = try PatternProgram(source: #"^(a+)+$"#)
    let input = String(repeating: "a", count: 4000) + "b"
    let started = Date()
    let outcome = program.search(input, limit: 0.2)

    XCTAssertEqual(outcome, .timedOut)
    XCTAssertLessThan(Date().timeIntervalSince(started), 3)

    let before = processCPUSeconds()

    Thread.sleep(forTimeInterval: 0.5)

    XCTAssertLessThan(processCPUSeconds() - before, 0.15)
  }

  func testAnOverlongInputCouldNotBeChecked() throws {
    let program = try PatternProgram(source: "a")

    XCTAssertEqual(
      program.search(String(repeating: "a", count: FormLimits.maxPatternInputUnits + 1)),
      .inputTooLong)
    XCTAssertEqual(
      program.search(String(repeating: "a", count: FormLimits.maxPatternInputUnits)), .matched)
  }

  /// Catches a result for a value the user has already replaced, and an older check that runs on
  /// after a newer value arrives. The limit is far longer than the wait, so three older checks
  /// that ran to their limit one after another would miss the deadline.
  func testTheNewestValueWinsAndOlderChecksStop() throws {
    let question = try decodeSpec(
      oneQuestion(#""type": "text", "validate": {"pattern": "^(a+)+$"}"#)
    ).questions[0]
    let queue = DispatchQueue(label: "delivery")
    let states = StateLog()
    let finished = expectation(description: "the last value is checked")
    let validator = FieldValidator(question: question, limit: 10, deliveryQueue: queue) {
      states.append($0)

      if $0 == .valid { finished.fulfill() }
    }
    let slow = FormAnswer.text(String(repeating: "a", count: 3000) + "b")

    validator.update(slow)
    validator.update(slow)
    validator.update(slow)
    validator.update(.text("aaa"))

    wait(for: [finished], timeout: 3)

    queue.sync {}

    XCTAssertEqual(states.all.last, .valid)
    XCTAssertFalse(states.all.contains(.couldNotCheck))
    XCTAssertFalse(
      states.all.contains { if case .invalid = $0 { return true } else { return false } })
  }

  /// Catches ICU giving up mid-match, which ends the enumeration with no match and no error. Read
  /// as no match, a valid input would show "does not match". The pattern below does match the
  /// input, since the input ends in the letter it needs. This pins the fix to the observed failure
  /// of this pattern on this ICU. Another ICU may finish the match, and then the test needs a
  /// harsher pattern.
  func testAMatchThatICUCannotFinishIsNotANoMatch() throws {
    let program = try PatternProgram(source: "(?:(?:[ab]{0,1000}){0,1000}){0,1000}c")
    let input = String(repeating: "a", count: 4094) + "c"

    XCTAssertNotEqual(program.search(input), .noMatch)
    XCTAssertEqual(try PatternProgram(source: "c").search("abd"), .noMatch)
  }

  func testATimedOutCheckLeavesTheFieldCouldNotCheck() throws {
    let question = try decodeSpec(
      oneQuestion(#""type": "text", "validate": {"pattern": "^(a+)+$"}"#)
    ).questions[0]
    let finished = expectation(description: "the check ends")
    let states = StateLog()
    let validator = FieldValidator(
      question: question, limit: 0.1, deliveryQueue: DispatchQueue(label: "delivery")
    ) {
      states.append($0)

      if $0 == .couldNotCheck { finished.fulfill() }
    }

    validator.update(.text(String(repeating: "a", count: 3000) + "b"))

    wait(for: [finished], timeout: 5)

    XCTAssertEqual(states.all, [.checking, .couldNotCheck])
  }

  func testAMatchDecidesTheFieldAndSearchIsUnanchored() throws {
    let question = try decodeSpec(
      oneQuestion(#""type": "string", "validate": {"pattern": "[0-9]+"}"#)
    ).questions[0]

    let verdict = FormChecker.verdict(question, .text("abc 12"))

    XCTAssertEqual(verdict, .needsPattern("abc 12"))

    let spec = FormSpec(title: nil, items: [.question(question)], buttons: FormSpec.defaultButtons)

    XCTAssertTrue(FormChecker.check(spec, answers: ["q": .text("abc 12")]).isEmpty)
    XCTAssertEqual(
      FormChecker.check(spec, answers: ["q": .text("abc")]).messages["q"], FormChecker.notMatching)
  }

  private func processCPUSeconds() -> Double {
    var usage = rusage()

    getrusage(RUSAGE_SELF, &usage)

    func seconds(_ value: timeval) -> Double { Double(value.tv_sec) + Double(value.tv_usec) / 1e6 }

    return seconds(usage.ru_utime) + seconds(usage.ru_stime)
  }
}

final class StateLog: @unchecked Sendable {
  private let lock = NSLock()
  private var states: [FieldState] = []

  func append(_ state: FieldState) { lock.withLock { states.append(state) } }

  var all: [FieldState] { lock.withLock { states } }
}
