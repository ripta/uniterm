import Foundation

/// Why a `pattern` is refused. The text names the construct. The reader adds the spec field.
public struct PatternError: Error, Equatable, CustomStringConvertible, Sendable {
  public let reason: String

  public init(_ reason: String) { self.reason = reason }

  public var description: String { reason }
}

/// A class escape such as `\d`, with the meaning ECMA-262 gives it. The ICU spelling of each is
/// written out by the emitter, since ICU's own `\d`, `\w`, and `\s` cover more characters.
enum PatternClassEscape: Equatable, Sendable {
  case digit
  case notDigit
  case word
  case notWord
  case space
  case notSpace
}

enum PatternSetItem: Equatable, Sendable {
  case scalar(UInt32)
  case range(UInt32, UInt32)
  case classEscape(PatternClassEscape)
  case property(icuName: String, negated: Bool)
}

struct PatternSet: Equatable, Sendable {
  var negated: Bool
  var items: [PatternSetItem]
}

/// The parse tree of a `pattern`. The emitter writes ICU syntax from it. The source text never
/// reaches ICU.
indirect enum PatternNode: Equatable, Sendable {
  case empty
  case scalar(UInt32)
  case anyCharacter
  case classEscape(PatternClassEscape)
  case property(icuName: String, negated: Bool)
  case set(PatternSet)
  case lineStart
  case lineEnd
  case wordBoundary
  case notWordBoundary
  case group(PatternNode)
  case lookahead(PatternNode, negative: Bool)
  case sequence([PatternNode])
  case alternation([PatternNode])
  case quantified(PatternNode, minimum: Int, maximum: Int?, lazy: Bool)
}

/// A parser for ECMA-262's `Pattern` grammar in Unicode mode, the `u` flag. It accepts a subset.
/// A construct with no proven translation onto ICU refuses, naming the construct:
///
/// - every backreference, numbered or named
/// - lookbehind
/// - a `\p{...}` name outside `PatternProperties`
/// - a lone surrogate escape
///
/// Unicode mode refuses what the legacy grammar tolerates, such as an unescaped `{`, `}`, or `]`,
/// an identity escape of an ordinary letter, and a quantifier on a lookahead.
struct PatternParser {
  static let maxDepth = 16
  static let maxNodes = 2048
  static let maxRepeat = 1000

  private let scalars: [UInt32]
  private var index = 0
  private var nodes = 0
  private var groupNames = Set<String>()

  init(_ source: String) {
    scalars = source.unicodeScalars.map(\.value)
  }

  static func parse(_ source: String) throws -> PatternNode {
    var parser = PatternParser(source)
    let node = try parser.disjunction(depth: 0)

    guard parser.index == parser.scalars.count else {
      throw PatternError("an unmatched \")\"")
    }

    return node
  }

  private var peek: UInt32? { index < scalars.count ? scalars[index] : nil }

  private func peek(at offset: Int) -> UInt32? {
    index + offset < scalars.count ? scalars[index + offset] : nil
  }

  private func ascii(_ character: Character) -> UInt32 { character.unicodeScalars.first!.value }

  private mutating func take(_ character: Character) -> Bool {
    guard peek == ascii(character) else { return false }

    index += 1

    return true
  }

  private mutating func count() throws {
    nodes += 1

    guard nodes <= Self.maxNodes else {
      throw PatternError("a pattern with over \(Self.maxNodes) parts")
    }
  }

  private mutating func disjunction(depth: Int) throws -> PatternNode {
    guard depth <= Self.maxDepth else {
      throw PatternError("groups nested over \(Self.maxDepth) deep")
    }

    var branches = [try alternative(depth: depth)]

    while take("|") {
      branches.append(try alternative(depth: depth))
    }

    return branches.count == 1 ? branches[0] : .alternation(branches)
  }

  private mutating func alternative(depth: Int) throws -> PatternNode {
    var terms: [PatternNode] = []

    while let next = peek, next != ascii("|"), next != ascii(")") {
      terms.append(try term(depth: depth))
    }

    switch terms.count {
    case 0: return .empty
    case 1: return terms[0]
    default: return .sequence(terms)
    }
  }

  private mutating func term(depth: Int) throws -> PatternNode {
    try count()

    let next = peek!

    switch next {
    case ascii("^"):
      index += 1
      try noQuantifier("^")

      return .lineStart

    case ascii("$"):
      index += 1
      try noQuantifier("$")

      return .lineEnd

    case ascii("\\") where peek(at: 1) == ascii("b") || peek(at: 1) == ascii("B"):
      let negated = peek(at: 1) == ascii("B")

      index += 2
      try noQuantifier(negated ? "\\B" : "\\b")

      return negated ? .notWordBoundary : .wordBoundary

    case ascii("("):
      return try group(depth: depth)

    default:
      return try quantified(try atom())
    }
  }

  private func noQuantifier(_ what: String) throws {
    if let next = peek, [ascii("*"), ascii("+"), ascii("?"), ascii("{")].contains(next) {
      throw PatternError("a quantifier after \(what), which has nothing to repeat")
    }
  }

  private mutating func group(depth: Int) throws -> PatternNode {
    index += 1

    if take("?") {
      if take(":") {
        let body = try disjunction(depth: depth + 1)

        try close()

        return try quantified(.group(body))
      }

      if take("=") { return try lookahead(negative: false, depth: depth) }

      if take("!") { return try lookahead(negative: true, depth: depth) }

      if peek == ascii("<") {
        if peek(at: 1) == ascii("=") || peek(at: 1) == ascii("!") {
          throw PatternError("a lookbehind, \"(?<=\" or \"(?<!\"")
        }

        index += 1

        try groupName()

        let body = try disjunction(depth: depth + 1)

        try close()

        return try quantified(.group(body))
      }

      throw PatternError(
        "a group that starts \"(?\" and is not \"(?:\", \"(?=\", \"(?!\", or \"(?<name>\"")
    }

    let body = try disjunction(depth: depth + 1)

    try close()

    return try quantified(.group(body))
  }

  private mutating func lookahead(negative: Bool, depth: Int) throws -> PatternNode {
    let body = try disjunction(depth: depth + 1)

    try close()

    if let next = peek, [ascii("*"), ascii("+"), ascii("?"), ascii("{")].contains(next) {
      throw PatternError("a quantifier after a lookahead, which Unicode mode refuses")
    }

    return .lookahead(body, negative: negative)
  }

  private mutating func close() throws {
    guard take(")") else { throw PatternError("a \"(\" that never closes") }
  }

  private mutating func groupName() throws {
    var name = ""

    while let next = peek, next != ascii(">") {
      guard let scalar = Unicode.Scalar(next), scalar.isASCII,
        scalar.properties.isAlphabetic || scalar == "_" || scalar == "$"
          || (!name.isEmpty && (0x30...0x39).contains(next))
      else { throw PatternError("a group name that is not an ASCII identifier") }

      name.unicodeScalars.append(scalar)
      index += 1
    }

    guard take(">"), !name.isEmpty else { throw PatternError("a group name that never closes") }

    guard groupNames.insert(name).inserted else {
      throw PatternError("the group name \"\(name)\", which appears twice")
    }
  }

  private mutating func atom() throws -> PatternNode {
    let next = peek!

    switch next {
    case ascii("."):
      index += 1

      return .anyCharacter

    case ascii("["):
      return try characterClass()

    case ascii("\\"):
      index += 1

      return try atomEscape()

    case ascii("*"), ascii("+"), ascii("?"):
      throw PatternError("a quantifier with nothing to repeat")

    case ascii("{"), ascii("}"), ascii("]"):
      throw PatternError(
        "an unescaped \"\(Character(Unicode.Scalar(next)!))\", which Unicode mode refuses")

    default:
      index += 1

      return .scalar(next)
    }
  }

  private mutating func quantified(_ atom: PatternNode) throws -> PatternNode {
    guard let next = peek else { return atom }

    var minimum = 0
    var maximum: Int?

    switch next {
    case ascii("*"): index += 1
    case ascii("+"):
      index += 1
      minimum = 1
    case ascii("?"):
      index += 1
      maximum = 1
    case ascii("{"):
      index += 1
      minimum = try repeatCount()
      maximum = minimum

      if take(",") {
        maximum = peek == ascii("}") ? nil : try repeatCount()
      }

      guard take("}") else { throw PatternError("a \"{\" that is not a quantifier") }

      if let maximum, maximum < minimum {
        throw PatternError("a quantifier whose maximum is below its minimum")
      }

    default: return atom
    }

    let lazy = take("?")

    if let after = peek, [ascii("*"), ascii("+"), ascii("?"), ascii("{")].contains(after) {
      throw PatternError("a quantifier after a quantifier, which has nothing to repeat")
    }

    return .quantified(atom, minimum: minimum, maximum: maximum, lazy: lazy)
  }

  private mutating func repeatCount() throws -> Int {
    var value = 0
    var digits = 0

    while let next = peek, (0x30...0x39).contains(next) {
      value = value * 10 + Int(next - 0x30)
      digits += 1
      index += 1

      guard value <= Self.maxRepeat else {
        throw PatternError("a repeat count over \(Self.maxRepeat)")
      }
    }

    guard digits > 0 else { throw PatternError("a \"{\" that is not a quantifier") }

    return value
  }

  private static let syntaxCharacters = Set("^$\\.*+?()[]{}|/".unicodeScalars.map(\.value))

  /// The escapes ECMA-262 allows both inside and outside a class, after the backslash.
  private mutating func commonEscape(inClass: Bool) throws -> PatternSetItem {
    guard let next = peek else { throw PatternError("a backslash at the end of the pattern") }

    index += 1

    switch Character(Unicode.Scalar(next) ?? "?") {
    case "d": return .classEscape(.digit)
    case "D": return .classEscape(.notDigit)
    case "w": return .classEscape(.word)
    case "W": return .classEscape(.notWord)
    case "s": return .classEscape(.space)
    case "S": return .classEscape(.notSpace)
    case "t": return .scalar(0x09)
    case "n": return .scalar(0x0A)
    case "v": return .scalar(0x0B)
    case "f": return .scalar(0x0C)
    case "r": return .scalar(0x0D)

    case "0":
      if let after = peek, (0x30...0x39).contains(after) {
        throw PatternError("an octal escape, which Unicode mode refuses")
      }

      return .scalar(0)

    case "1", "2", "3", "4", "5", "6", "7", "8", "9":
      throw PatternError(
        inClass
          ? "a decimal escape in a class"
          : "a backreference, \"\\\(Character(Unicode.Scalar(next)!))\"")

    case "k": throw PatternError("a named backreference, \"\\k\"")

    case "c":
      guard let letter = peek, (0x41...0x5A).contains(letter) || (0x61...0x7A).contains(letter)
      else { throw PatternError("a control escape, \"\\c\", without a letter") }

      index += 1

      return .scalar(letter % 32)

    case "x":
      guard let value = hexDigits(exactly: 2) else {
        throw PatternError("a \"\\x\" escape without two hex digits")
      }

      return .scalar(value)

    case "u": return .scalar(try unicodeEscape())

    case "p", "P":
      let negated = next == ascii("P")

      return try property(negated: negated)

    default:
      if Self.syntaxCharacters.contains(next) { return .scalar(next) }

      if inClass, next == ascii("-") { return .scalar(next) }

      let shown = Unicode.Scalar(next).map { String($0) } ?? "?"

      throw PatternError("the escape \"\\\(shown)\", which Unicode mode refuses")
    }
  }

  private mutating func atomEscape() throws -> PatternNode {
    switch try commonEscape(inClass: false) {
    case .scalar(let value): return .scalar(value)
    case .classEscape(let escape): return .classEscape(escape)
    case .property(let name, let negated): return .property(icuName: name, negated: negated)
    case .range: preconditionFailure("an escape is never a range")
    }
  }

  private mutating func hexDigits(exactly count: Int) -> UInt32? {
    guard index + count <= scalars.count else { return nil }

    var value: UInt32 = 0

    for offset in 0..<count {
      guard let digit = Self.hexValue(scalars[index + offset]) else { return nil }

      value = value * 16 + digit
    }

    index += count

    return value
  }

  private static func hexValue(_ scalar: UInt32) -> UInt32? {
    switch scalar {
    case 0x30...0x39: return scalar - 0x30
    case 0x41...0x46: return scalar - 0x41 + 10
    case 0x61...0x66: return scalar - 0x61 + 10
    default: return nil
    }
  }

  private mutating func unicodeEscape() throws -> UInt32 {
    if take("{") {
      var value: UInt32 = 0
      var digits = 0

      while let next = peek, let digit = Self.hexValue(next) {
        value = value * 16 + digit
        digits += 1
        index += 1

        guard value <= 0x10FFFF else { throw PatternError("a \"\\u{...}\" escape past U+10FFFF") }
      }

      guard digits > 0, take("}") else { throw PatternError("a malformed \"\\u{...}\" escape") }

      return try checkedScalar(value)
    }

    guard let first = hexDigits(exactly: 4) else {
      throw PatternError("a \"\\u\" escape without four hex digits")
    }

    guard (0xD800...0xDBFF).contains(first) else { return try checkedScalar(first) }

    guard peek == ascii("\\"), peek(at: 1) == ascii("u") else {
      throw PatternError("a lone surrogate escape")
    }

    let saved = index

    index += 2

    guard let second = hexDigits(exactly: 4), (0xDC00...0xDFFF).contains(second) else {
      index = saved

      throw PatternError("a lone surrogate escape")
    }

    return 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
  }

  private func checkedScalar(_ value: UInt32) throws -> UInt32 {
    guard Unicode.Scalar(value) != nil else { throw PatternError("a lone surrogate escape") }

    return value
  }

  private mutating func property(negated: Bool) throws -> PatternSetItem {
    let letter = negated ? "P" : "p"

    guard take("{") else { throw PatternError("\"\\\(letter)\" without a name in braces") }

    var text = ""

    while let next = peek, next != ascii("}") {
      guard let scalar = Unicode.Scalar(next), scalar.isASCII else {
        throw PatternError("the property name \"\\\(letter){\(text)...\", which is not ASCII")
      }

      text.unicodeScalars.append(scalar)
      index += 1
    }

    guard take("}") else { throw PatternError("a \"\\\(letter){\" that never closes") }

    let parts = text.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)

    guard !parts.isEmpty, parts.count <= 2,
      let icu = PatternProperties.icuName(
        forName: String(parts[0]), value: parts.count == 2 ? String(parts[1]) : nil)
    else {
      throw PatternError(
        "the property \"\\\(letter){\(text)}\", which is not in the supported table")
    }

    return .property(icuName: icu, negated: negated)
  }

  private mutating func characterClass() throws -> PatternNode {
    index += 1

    let negated = take("^")
    var items: [PatternSetItem] = []

    while true {
      guard let next = peek else { throw PatternError("a \"[\" that never closes") }

      if next == ascii("]") {
        index += 1

        break
      }

      try count()

      let low = try classAtom()

      guard peek == ascii("-"), let after = peek(at: 1), after != ascii("]") else {
        items.append(low)

        continue
      }

      index += 1

      let high = try classAtom()

      guard case .scalar(let lowValue) = low, case .scalar(let highValue) = high else {
        throw PatternError("a range with a class escape as an end, which Unicode mode refuses")
      }

      guard lowValue <= highValue else { throw PatternError("a range whose ends are out of order") }

      items.append(.range(lowValue, highValue))
    }

    return .set(PatternSet(negated: negated, items: items))
  }

  private mutating func classAtom() throws -> PatternSetItem {
    guard let next = peek else { throw PatternError("a \"[\" that never closes") }

    index += 1

    guard next == ascii("\\") else { return .scalar(next) }

    if peek == ascii("b") {
      index += 1

      return .scalar(0x08)
    }

    if peek == ascii("B") { throw PatternError("\"\\B\" inside a class") }

    return try commonEscape(inClass: true)
  }
}
