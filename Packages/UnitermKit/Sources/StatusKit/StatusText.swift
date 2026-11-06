import Foundation

/// Cleans and bounds text before the status queue stores it.
///
/// Status text can come from a program's output, so it is never trusted as typed. Control
/// characters and bidirectional overrides cannot reach a row or the bar.
public enum StatusText {
  private static let ellipsis = "\u{2026}"

  /// Replaces every control character with a space, drops bidirectional overrides and isolates,
  /// trims the ends, and cuts the result to `maximumBytes` of UTF-8 on a character boundary.
  public static func bounded(_ text: String, maximumBytes: Int) -> String {
    var cleaned = String.UnicodeScalarView()

    for scalar in text.unicodeScalars {
      if isBidirectionalControl(scalar) { continue }

      if scalar.properties.generalCategory == .control {
        cleaned.append(" ")
      } else {
        cleaned.append(scalar)
      }
    }

    let trimmed = String(cleaned).trimmingCharacters(in: .whitespaces)

    guard trimmed.utf8.count > maximumBytes else { return trimmed }

    let room = max(0, maximumBytes - ellipsis.utf8.count)
    var kept = ""
    var used = 0

    for character in trimmed {
      let size = String(character).utf8.count
      guard used + size <= room else { break }

      kept.append(character)
      used += size
    }

    return kept + ellipsis
  }

  private static func isBidirectionalControl(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x202A...0x202E, 0x2066...0x2069, 0x200E, 0x200F, 0x061C: return true
    default: return false
    }
  }
}
