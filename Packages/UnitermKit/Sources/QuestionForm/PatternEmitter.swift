import Foundation

/// Writes ICU regular expression syntax from a parse tree. Nothing of the source text passes
/// through. Every literal is a `\x{...}` escape, so no character can take ICU's meaning, and every
/// token whose ICU meaning differs from ECMA-262's is spelled out.
enum PatternEmitter {
  static func emit(_ node: PatternNode) -> String {
    switch node {
    case .empty:
      return "(?:)"

    case .scalar(let value):
      return hex(value)

    case .anyCharacter:
      return "[^\\x{A}\\x{D}\\x{2028}\\x{2029}]"

    case .classEscape(let escape):
      return "[" + setText(escape) + "]"

    case .property(let name, let negated):
      return (negated ? "\\P{" : "\\p{") + name + "}"

    case .set(let set):
      return emit(set)

    case .lineStart:
      return "\\A"

    case .lineEnd:
      return "\\z"

    case .wordBoundary:
      return "(?:(?<=\(word))(?!\(word))|(?<!\(word))(?=\(word)))"

    case .notWordBoundary:
      return "(?:(?<=\(word))(?=\(word))|(?<!\(word))(?!\(word)))"

    case .group(let body):
      return "(?:" + emit(body) + ")"

    case .lookahead(let body, let negative):
      return (negative ? "(?!" : "(?=") + emit(body) + ")"

    case .sequence(let parts):
      return parts.map(emit).joined()

    case .alternation(let branches):
      return branches.map(emit).joined(separator: "|")

    case .quantified(let body, let minimum, let maximum, let lazy):
      return emit(body) + quantifier(minimum: minimum, maximum: maximum) + (lazy ? "?" : "")
    }
  }

  /// ECMA-262's word characters. ICU's own `\w` and `\b` follow Unicode.
  private static let word = "[\\x{30}-\\x{39}\\x{41}-\\x{5A}\\x{5F}\\x{61}-\\x{7A}]"

  private static func hex(_ value: UInt32) -> String { "\\x{" + String(value, radix: 16) + "}" }

  private static func quantifier(minimum: Int, maximum: Int?) -> String {
    switch (minimum, maximum) {
    case (0, nil): return "*"
    case (1, nil): return "+"
    case (0, 1): return "?"
    case (let low, nil): return "{\(low),}"
    case (let low, let high?) where low == high: return "{\(low)}"
    case (let low, let high?): return "{\(low),\(high)}"
    }
  }

  /// The contents of an ICU set for a class escape. A negated escape nests a negated set.
  private static func setText(_ escape: PatternClassEscape) -> String {
    switch escape {
    case .digit: return "\\x{30}-\\x{39}"
    case .notDigit: return "^" + setText(.digit)
    case .word: return "\\x{30}-\\x{39}\\x{41}-\\x{5A}\\x{5F}\\x{61}-\\x{7A}"
    case .notWord: return "^" + setText(.word)

    // WhiteSpace and LineTerminator of ECMA-262: tab to carriage return, space, no-break space,
    // the Zs category, the line and paragraph separators, and the byte order mark.
    case .space:
      return
        "\\x{9}-\\x{D}\\x{20}\\x{A0}\\x{1680}\\x{2000}-\\x{200A}\\x{2028}\\x{2029}\\x{202F}"
        + "\\x{205F}\\x{3000}\\x{FEFF}"
    case .notSpace: return "^" + setText(.space)
    }
  }

  private static func emit(_ set: PatternSet) -> String {
    if set.items.isEmpty {
      return set.negated ? "[\\x{0}-\\x{10FFFF}]" : "(?!)"
    }

    var text = set.negated ? "[^" : "["

    for item in set.items {
      switch item {
      case .scalar(let value): text += hex(value)
      case .range(let low, let high): text += hex(low) + "-" + hex(high)
      case .classEscape(let escape): text += "[" + setText(escape) + "]"
      case .property(let name, let negated): text += (negated ? "\\P{" : "\\p{") + name + "}"
      }
    }

    return text + "]"
  }
}
