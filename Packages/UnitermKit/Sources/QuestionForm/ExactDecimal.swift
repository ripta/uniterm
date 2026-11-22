import Foundation

/// A number as the script wrote it, compared as a decimal and never as a double. A double reads
/// 0.1 as a binary fraction, so `0.3` would not be a multiple of `0.1`. Foundation's `Decimal`
/// holds a decimal literal exactly.
public struct ExactDecimal: Equatable, Comparable, Hashable, Sendable {
  /// The literal, as the JSON grammar spells a number.
  public let literal: String

  public let value: Decimal

  /// Reads a JSON number literal within the digit and exponent caps. Foundation's parser stops at
  /// the first byte it does not know, so the grammar is checked here first.
  public init?(literal: String) {
    let bytes = Array(literal.utf8)
    var index = 0
    var digits = 0
    var exponent = 0

    func scanDigits() -> Int {
      let start = index

      while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }

      return index - start
    }

    if index < bytes.count, bytes[index] == 0x2D { index += 1 }

    let start = index
    let whole = scanDigits()

    guard whole > 0, whole == 1 || bytes[start] != 0x30 else { return nil }

    digits += whole

    if index < bytes.count, bytes[index] == 0x2E {
      index += 1

      let fraction = scanDigits()

      guard fraction > 0 else { return nil }

      digits += fraction
    }

    if index < bytes.count, bytes[index] == 0x65 || bytes[index] == 0x45 {
      index += 1

      var sign = 1

      if index < bytes.count, bytes[index] == 0x2B || bytes[index] == 0x2D {
        sign = bytes[index] == 0x2D ? -1 : 1
        index += 1
      }

      let exponentStart = index
      let count = scanDigits()

      guard count > 0, count <= 3 else { return nil }

      exponent = sign * Int(String(decoding: bytes[exponentStart..<index], as: UTF8.self))!
    }

    guard index == bytes.count, digits <= FormLimits.maxNumberDigits,
      abs(exponent) <= FormLimits.maxNumberExponent,
      let value = Decimal(string: literal, locale: Locale(identifier: "en_US_POSIX"))
    else { return nil }

    self.literal = literal
    self.value = value
  }

  public static func < (lhs: ExactDecimal, rhs: ExactDecimal) -> Bool { lhs.value < rhs.value }

  public var isWhole: Bool {
    var rounded = Decimal()
    var original = value

    NSDecimalRound(&rounded, &original, 0, .down)

    return rounded == value
  }

  public var isNegative: Bool { value < 0 }

  /// Whether this is a whole multiple of `step`. A quotient that is a whole number, times the
  /// step, must give this value back, so a rounded quotient never passes.
  public func isMultiple(of step: ExactDecimal) -> Bool {
    guard step.value != 0 else { return false }

    var quotient = Decimal()
    var left = value
    var right = step.value

    NSDecimalDivide(&quotient, &left, &right, .plain)

    var whole = Decimal()

    NSDecimalRound(&whole, &quotient, 0, .plain)

    return whole * step.value == value
  }

  /// The whole number this holds, when it is whole and within the integer cap.
  public var wholeNumber: Int64? {
    guard isWhole else { return nil }

    let limit = Decimal(FormLimits.maxIntegerMagnitude)

    guard value <= limit, value >= -limit else { return nil }

    return Int64(truncating: value as NSDecimalNumber)
  }

  /// The nearest double, for a reply that carries a number.
  public var doubleValue: Double { Double(literal) ?? 0 }
}
