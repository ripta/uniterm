import Foundation

/// The spreadsheet formats the data viewer recognizes and does not read.
public enum UnsupportedSpreadsheet: Sendable, Equatable {
  /// A binary workbook from Excel 97 to 2003.
  case legacyXLS

  /// Excel's binary workbook format, a ZIP archive of binary parts.
  case binaryXLSB

  /// An encrypted workbook. A password-protected `.xlsx` is an encrypted compound file.
  case passwordProtected

  /// Another Office file in the old compound format, such as a Word document.
  case otherOfficeFile

  var description: String {
    switch self {
    case .legacyXLS: return "an Excel 97-2003 workbook (.xls)"
    case .binaryXLSB: return "an Excel binary workbook (.xlsb)"
    case .passwordProtected: return "a password-protected Excel workbook"
    case .otherOfficeFile: return "an older Office file that is not a workbook"
    }
  }

  var advice: String {
    switch self {
    case .legacyXLS, .binaryXLSB:
      return
        "The data viewer opens .xlsx workbooks. Save a copy as .xlsx or CSV in Excel, then open that."

    case .passwordProtected:
      return
        "The data viewer cannot read an encrypted workbook. Remove the password in Excel, save a copy, then open that."

    case .otherOfficeFile:
      return "The data viewer opens .xlsx workbooks."
    }
  }
}

/// Why a source did not load. The text is for the pane, so each case says what to do or what
/// happened, and none of them says "corrupt".
public enum TableLoadError: Error, Equatable, Sendable, LocalizedError {
  case missing(path: String)
  case permissionDenied(path: String)
  case notARegularFile(path: String, kind: String)
  case unsupportedFormat(path: String, description: String)

  /// A spreadsheet that is not an `.xlsx` workbook, named by what it is.
  case unsupportedSpreadsheet(path: String, kind: UnsupportedSpreadsheet)

  /// A workbook that grew past a size cap while it was read. `what` says which cap.
  case spreadsheetTooLarge(path: String, what: String)

  /// A file with a spreadsheet extension that does not read as a workbook.
  case invalidSpreadsheet(path: String, reason: String)
  case unreadable(path: String, reason: String)

  /// JSON that does not parse. `line` is 1-based, or 0 when it is not known.
  case invalidJSON(path: String, reason: String, line: Int)

  /// A JSON value on its own, such as a number, has no rows or columns to show.
  case notATable(path: String, what: String)

  public var errorDescription: String? {
    switch self {
    case .missing(let path):
      return "\u{201C}\(Self.name(of: path))\u{201D} is missing. It was at \(path)."

    case .permissionDenied(let path):
      return
        "uniterm does not have permission to read \u{201C}\(Self.name(of: path))\u{201D}. "
        + "Allow access to its folder in System Settings > Privacy & Security, then open it again."

    case .notARegularFile(let path, let kind):
      return "\u{201C}\(Self.name(of: path))\u{201D} is \(kind), not a file with data in it."

    case .unsupportedFormat(let path, let description):
      return
        "\u{201C}\(Self.name(of: path))\u{201D} is \(description). "
        + "The data viewer does not read that format."

    case .unsupportedSpreadsheet(let path, let kind):
      return
        "\u{201C}\(Self.name(of: path))\u{201D} is \(kind.description). \(kind.advice)"

    case .spreadsheetTooLarge(let path, let what):
      return
        "\u{201C}\(Self.name(of: path))\u{201D} stopped loading because \(what). "
        + "The data viewer limits how far a workbook may expand, so a hostile file cannot use all memory."

    case .invalidSpreadsheet(let path, let reason):
      return
        "\u{201C}\(Self.name(of: path))\u{201D} could not be read as an .xlsx workbook: \(reason)."

    case .unreadable(let path, let reason):
      return "\u{201C}\(Self.name(of: path))\u{201D} could not be read: \(reason)."

    case .invalidJSON(let path, let reason, let line):
      let place = line > 0 ? " at line \(line)" : ""

      return "\u{201C}\(Self.name(of: path))\u{201D} is not valid JSON: \(reason)\(place)."

    case .notATable(let path, let what):
      return
        "\u{201C}\(Self.name(of: path))\u{201D} holds only \(what), so there are no rows to show."
    }
  }

  static func name(of path: String) -> String {
    (path as NSString).lastPathComponent
  }

  /// The error for a failed system call on `path`.
  static func posix(_ code: Int32, path: String) -> TableLoadError {
    switch code {
    case ENOENT, ENOTDIR:
      return .missing(path: path)

    case EACCES, EPERM:
      return .permissionDenied(path: path)

    default:
      return .unreadable(path: path, reason: String(cString: strerror(code)))
    }
  }
}
