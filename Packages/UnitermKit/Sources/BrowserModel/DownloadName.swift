import Foundation

/// The file name a download takes, cleaned from the name the page or the server suggested.
///
/// A page chooses the suggested name, so it may carry path separators, a `..`, a leading dot that
/// hides the file, a bidirectional override that disguises the extension, or a run of text no file
/// system accepts. Everything here is pure, so a table proves each case.
public enum DownloadName {
  /// The name used when nothing usable is left.
  public static let fallback = "download"

  /// The most UTF-8 bytes a cleaned name keeps. APFS allows 255, and the rest leaves room for a
  /// number that makes the name unique.
  public static let maximumBytes = 200

  /// The longest extension that stays on a cut name. A longer tail is not an extension.
  static let maximumExtensionBytes = 16

  private static let reserved: Set<Character> = ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]

  /// A name safe to create in the Downloads folder. A separator or another reserved character
  /// becomes an underscore, so `../x` cannot climb out of the folder and keeps its readable tail.
  /// Control characters, format characters such as zero-width marks and the byte order mark, line
  /// and paragraph separators, and the invisible filler letters are dropped. Every kind of space
  /// becomes one plain space, and a run of spaces becomes one, so a long gap cannot push the real
  /// extension out of view. Leading dots and spaces, and trailing dots and spaces, are trimmed. An
  /// empty result is `download`. A name over `maximumBytes` is cut in its stem and keeps its
  /// extension.
  public static func sanitize(_ suggested: String) -> String {
    var scalars = String.UnicodeScalarView()
    var lastWasSpace = false

    for scalar in suggested.unicodeScalars {
      if isInvisible(scalar) { continue }

      if scalar.properties.generalCategory == .spaceSeparator {
        if !lastWasSpace { scalars.append(" ") }

        lastWasSpace = true
        continue
      }

      lastWasSpace = false

      if reserved.contains(Character(scalar)) {
        scalars.append("_")
      } else {
        scalars.append(scalar)
      }
    }

    var name = String(scalars)

    while let first = name.first, first == "." || first == " " { name.removeFirst() }

    while let last = name.last, last == "." || last == " " { name.removeLast() }

    guard !name.isEmpty else { return fallback }

    return cut(name)
  }

  /// `name` for the first attempt, then `stem 2.ext`, `stem 3.ext`, and so on. The number goes
  /// before the extension, as Finder numbers a copy.
  public static func numbered(_ name: String, attempt: Int) -> String {
    guard attempt > 1 else { return name }

    let (stem, ext) = split(name)

    return "\(stem) \(attempt)\(ext)"
  }

  private static func cut(_ name: String) -> String {
    guard name.utf8.count > maximumBytes else { return name }

    var (stem, ext) = split(name)

    if ext.utf8.count > maximumExtensionBytes {
      stem = name
      ext = ""
    }

    let room = maximumBytes - ext.utf8.count
    var kept = ""

    for character in stem {
      guard kept.utf8.count + String(character).utf8.count <= room else { break }

      kept.append(character)
    }

    while let last = kept.last, last == "." || last == " " { kept.removeLast() }

    return kept.isEmpty ? fallback : kept + ext
  }

  /// The stem and the extension with its dot. A dot at the start or end is not an extension
  /// separator.
  private static func split(_ name: String) -> (stem: String, ext: String) {
    guard let dot = name.lastIndex(of: "."), dot != name.startIndex,
      name.index(after: dot) != name.endIndex
    else { return (name, "") }

    return (String(name[..<dot]), String(name[dot...]))
  }

  /// Scalars that show nothing, or reorder what shows. The general categories cover controls,
  /// format characters, and the line and paragraph separators. The fillers and the blank braille
  /// pattern are letters and symbols that draw as blank.
  private static func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.properties.generalCategory {
    case .control, .format, .lineSeparator, .paragraphSeparator:
      return true

    default:
      break
    }

    switch scalar.value {
    case 0x115F, 0x1160, 0x3164, 0xFFA0, 0x2800: return true
    default: return false
    }
  }
}

/// What the status bar says about a download's end. The file name is already cleaned, and the
/// reason is the system's text for the failure.
public enum DownloadMessage {
  public static func finished(_ name: String) -> String {
    "Downloaded \(AddressDisplay.bounded(name))."
  }

  public static func failed(_ name: String, reason: String) -> String {
    let reason = AddressDisplay.bounded(reason)
    let stop = reason.hasSuffix(".") || reason.isEmpty ? "" : "."

    return "Could not download \(AddressDisplay.bounded(name)). \(reason)\(stop)"
      .trimmingCharacters(in: .whitespaces)
  }

  public static func moved(_ name: String) -> String {
    "Could not show \(AddressDisplay.bounded(name)). It was moved or deleted."
  }
}

/// A page's own words, made fit for a question. A page chooses its tab title, so the dialog that
/// names a tab drops bidirectional controls, turns other control characters and runs of
/// whitespace into one space, and cuts the result.
public enum RunningLabel {
  public static let maximumCharacters = 80

  public static func clean(_ text: String, fallback: String) -> String {
    let words = AddressDisplay.bounded(text)
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")

    guard !words.isEmpty else { return fallback }

    guard words.count > maximumCharacters else { return words }

    return String(words.prefix(maximumCharacters)) + "\u{2026}"
  }
}

/// The text of a page's own dialog, made fit to show. A page chooses the message, so bidirectional
/// controls go, other control characters other than a line break become spaces, and the text is
/// cut.
public enum DialogText {
  public static let maximumCharacters = 600

  public static func bounded(_ text: String) -> String {
    var kept = String.UnicodeScalarView()
    var count = 0

    for scalar in text.unicodeScalars {
      switch scalar.value {
      case 0x202A...0x202E, 0x2066...0x2069, 0x200E, 0x200F, 0x061C:
        continue

      case 0x0A:
        kept.append(scalar)

      default:
        kept.append(scalar.properties.generalCategory == .control ? " " : scalar)
      }

      count += 1

      if count >= maximumCharacters * 4 { break }
    }

    let text = String(kept).trimmingCharacters(in: .whitespacesAndNewlines)

    guard text.count > maximumCharacters else { return text }

    return String(text.prefix(maximumCharacters)) + "\u{2026}"
  }
}
