import Foundation

/// How a number format shows a number.
enum NumberStyle: UInt8, Sendable {
  case plain = 0
  case date
  case time
  case dateTime

  /// A time format in square brackets, such as `[h]:mm:ss`, counts hours past 24.
  case elapsed
}

/// Which number formats are dates, and how a serial number becomes one.
///
/// Excel stores a date as the days since an epoch, with the time of day as a fraction. The 1900
/// system counts 1900-01-01 as day 1 and wrongly treats 1900 as a leap year, so day 60 is the
/// nonexistent 1900-02-29. Every later day is one more than a calendar count from 1899-12-30. The
/// 1904 system counts 1904-01-01 as day 0 and has no such day.
enum SpreadsheetDates {
  /// The style of a built-in number format id, which the styles part does not spell out.
  static func builtIn(_ id: Int) -> NumberStyle {
    switch id {
    case 14...17, 27...31, 36, 50...58: return .date
    case 18...21, 32...35, 45, 47: return .time
    case 46: return .elapsed
    case 22: return .dateTime
    default: return .plain
    }
  }

  /// The style of a format code. Only the first section counts. Quoted text, escaped letters, and
  /// bracketed conditions and colors do not. An `m` is a month beside a date and a minute beside a
  /// time.
  static func classify(_ code: String) -> NumberStyle {
    var hasDate = false
    var hasTime = false
    var hasMonthOrMinute = false
    var elapsed = false

    let characters = Array(code)
    var index = 0

    scan: while index < characters.count {
      let character = characters[index]

      switch character {
      case ";":
        break scan

      case "\"":
        index += 1

        while index < characters.count, characters[index] != "\"" {
          index += 1
        }

      case "\\", "_", "*":
        index += 1

      case "[":
        var inner = ""
        index += 1

        while index < characters.count, characters[index] != "]" {
          inner.append(characters[index])
          index += 1
        }

        if let first = inner.lowercased().first, "hms".contains(first),
          inner.lowercased().allSatisfy({ $0 == first })
        {
          hasTime = true
          elapsed = elapsed || first == "h"
        }

      case "y", "Y", "d", "D":
        hasDate = true

      case "h", "H", "s", "S":
        hasTime = true

      case "m", "M":
        hasMonthOrMinute = true

      case "A", "a":
        let rest = String(characters[index...].prefix(5)).uppercased()

        if rest.hasPrefix("AM/PM") || rest.hasPrefix("A/P") { hasTime = true }

      default:
        break
      }

      index += 1
    }

    if hasMonthOrMinute, !hasTime { hasDate = true }

    switch (hasDate, hasTime) {
    case (true, true): return .dateTime
    case (true, false): return .date
    case (false, true): return elapsed ? .elapsed : .time
    case (false, false): return .plain
    }
  }

  /// The serial number as text, or nil when it is not a date this system can show. The caller then
  /// shows the number as it was stored.
  static func format(_ serial: Double, style: NumberStyle, date1904: Bool) -> String? {
    guard style != .plain, serial.isFinite, serial >= 0, serial < 2_958_466 else { return nil }

    // Excel rounds the time of day to the millisecond, then shows whole seconds, cut and not
    // rounded. So a time half a second short of midnight stays on its day, and one within half a
    // millisecond of midnight is the next day.
    var days = Int(serial.rounded(.down))
    var milliseconds = Int(((serial - Double(days)) * 86_400_000).rounded())

    if milliseconds >= 86_400_000 {
      milliseconds -= 86_400_000
      days += 1
    }

    let seconds = milliseconds / 1_000

    let clock = "\(pad(seconds / 3_600)):\(pad(seconds % 3_600 / 60)):\(pad(seconds % 60))"

    switch style {
    case .plain:
      return nil

    case .time:
      return clock

    case .elapsed:
      let hours = days * 24 + seconds / 3_600
      return "\(hours):\(pad(seconds % 3_600 / 60)):\(pad(seconds % 60))"

    case .date, .dateTime:
      guard let date = dateText(days: days, date1904: date1904) else { return nil }

      return style == .date ? date : "\(date) \(clock)"
    }
  }

  private static func dateText(days: Int, date1904: Bool) -> String? {
    if date1904 {
      return civil(daysSinceEpoch: days + daysFromCivil(1904, 1, 1))
    }

    switch days {
    case 0: return "1900-01-00"
    case 60: return "1900-02-29"
    case 1..<60: return civil(daysSinceEpoch: days + daysFromCivil(1899, 12, 31))
    default: return civil(daysSinceEpoch: days + daysFromCivil(1899, 12, 30))
    }
  }

  private static func civil(daysSinceEpoch days: Int) -> String? {
    let (year, month, day) = civilFromDays(days)

    guard year >= 1, year <= 9_999 else { return nil }

    return
      "\(String(repeating: "0", count: max(0, 4 - String(year).count)))\(year)-\(pad(month))-\(pad(day))"
  }

  private static func pad(_ value: Int) -> String {
    value < 10 ? "0\(value)" : "\(value)"
  }

  /// Days since 1970-01-01 of a proleptic Gregorian date.
  static func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int {
    let y = month <= 2 ? year - 1 : year
    let era = (y >= 0 ? y : y - 399) / 400
    let yearOfEra = y - era * 400
    let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
    let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear

    return era * 146_097 + dayOfEra - 719_468
  }

  static func civilFromDays(_ days: Int) -> (year: Int, month: Int, day: Int) {
    let z = days + 719_468
    let era = (z >= 0 ? z : z - 146_096) / 146_097
    let dayOfEra = z - era * 146_097
    let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
    let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
    let monthPart = (5 * dayOfYear + 2) / 153
    let day = dayOfYear - (153 * monthPart + 2) / 5 + 1
    let month = monthPart < 10 ? monthPart + 3 : monthPart - 9
    let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)

    return (year, month, day)
  }
}
