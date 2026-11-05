import XCTest

@testable import TableData

final class SpreadsheetDatesTests: XCTestCase {
  /// Catches a format code that is read as a date because of a letter in quoted or escaped text, or
  /// a minute that is read as a month.
  func testFormatCodesAreClassifiedByTheirDateAndTimeLetters() {
    let cases: [(String, NumberStyle)] = [
      ("General", .plain),
      ("0.00", .plain),
      ("#,##0.00_);[Red](#,##0.00)", .plain),
      ("0.0%", .plain),
      ("0.00E+00", .plain),
      ("\"day\" 0", .plain),
      ("yyyy-mm-dd", .date),
      ("d-mmm-yy", .date),
      ("mmmm", .date),
      ("h:mm:ss", .time),
      ("h:mm AM/PM", .time),
      ("mm:ss", .time),
      ("[h]:mm:ss", .elapsed),
      ("[$-409]m/d/yy h:mm", .dateTime),
      ("yyyy-mm-dd hh:mm;@", .dateTime),
      ("\\y\\e\\a\\r 0", .plain),
    ]

    for (code, style) in cases {
      XCTAssertEqual(SpreadsheetDates.classify(code), style, code)
    }
  }

  /// Catches the civil-date arithmetic drifting at a leap day or a century.
  func testSerialsConvertAcrossLeapDaysAndCenturies() {
    let cases: [(Double, String)] = [
      (61, "1900-03-01"),
      (36_585, "2000-02-29"),
      (36_586, "2000-03-01"),
      (73_050, "2099-12-31"),
      (73_051, "2100-01-01"),
      (73_415, "2100-12-31"),
      (2_958_465, "9999-12-31"),
    ]

    for (serial, expected) in cases {
      XCTAssertEqual(SpreadsheetDates.format(serial, style: .date, date1904: false), expected)
    }

    XCTAssertNil(SpreadsheetDates.format(2_958_466, style: .date, date1904: false))
    XCTAssertNil(SpreadsheetDates.format(.nan, style: .date, date1904: false))
    XCTAssertEqual(
      SpreadsheetDates.format(0.999999999, style: .dateTime, date1904: false), "1900-01-01 00:00:00"
    )
  }

  /// Catches a date that rolls to the next day because the time of day was rounded to the second.
  /// Excel rounds to the millisecond and then cuts to whole seconds, so a time half a second short
  /// of midnight stays on its day in every style.
  func testATimeJustBeforeMidnightStaysOnItsDay() {
    let late = 44_927.999_995_37

    XCTAssertEqual(SpreadsheetDates.format(late, style: .date, date1904: false), "2023-01-01")
    XCTAssertEqual(
      SpreadsheetDates.format(late, style: .dateTime, date1904: false), "2023-01-01 23:59:59")
    XCTAssertEqual(SpreadsheetDates.format(late, style: .time, date1904: false), "23:59:59")

    XCTAssertEqual(
      SpreadsheetDates.format(44_927.999_999_999, style: .date, date1904: false), "2023-01-02")
  }
}
