import Foundation

/// Where a load came from. The source decides which schemes may load.
public enum NavigationSource: Sendable, Equatable {
  /// An address the user typed, and any other address the browser itself starts a load for.
  case typed

  /// A tab's stored address, loaded when its pane restores.
  case restored

  /// A command from a controlling program.
  case controller

  /// A link, a redirect, a script, or history. The page chose it.
  case page
}

/// Whether a load may go ahead.
public enum SchemeDecision: Sendable, Equatable {
  case allow
  case refuse(SchemeRefusal)
}

/// Why a load was refused. The text says why in words the status bar can show.
public enum SchemeRefusal: Sendable, Equatable {
  /// `file:`. Reading local files needs a read scope the browser does not have.
  case file

  /// `javascript:`. Script runs in a page, never from an address.
  case javascript

  /// A top-level `data:` page. It is a known vehicle for phishing.
  case data

  /// Any other scheme the browser does not load.
  case unsupported(scheme: String)

  /// An address with no scheme or host to load.
  case notAnAddress

  public func message(for rawAddress: String) -> String {
    let address = AddressDisplay.bounded(rawAddress)

    switch self {
    case .file:
      return "Did not load \(address). The browser does not open local files."

    case .javascript:
      return "Did not load \(address). An address cannot run script."

    case .data:
      return "Did not load \(address). A page made of data is not loaded as a top-level page."

    case .unsupported(let scheme):
      return "Did not load \(address). The browser does not load \(scheme): addresses."

    case .notAnAddress:
      return "\(address) is not a web address."
    }
  }
}

/// The one place that says which URL schemes the browser loads.
///
/// A typed address, a restored tab, and a controller's command load only `http`, `https`, and
/// `about:blank`. A page's own navigation also loads a `blob:` URL, which WebKit limits to the
/// origin that made it. A page may load `data:` and `about:srcdoc` into a subframe, never as a
/// top-level page. `file:` and `javascript:` never load.
public enum SchemePolicy {
  public static func decide(
    _ url: URL, source: NavigationSource, isMainFrame: Bool = true
  ) -> SchemeDecision {
    let scheme = url.scheme?.lowercased() ?? ""

    switch scheme {
    case "http", "https":
      return .allow

    case "about":
      return isBlank(url) || (source == .page && !isMainFrame && isSrcdoc(url))
        ? .allow : .refuse(.unsupported(scheme: scheme))

    case "file":
      return .refuse(.file)

    case "javascript":
      return .refuse(.javascript)

    case "blob":
      return source == .page ? .allow : .refuse(.unsupported(scheme: scheme))

    case "data":
      return source == .page && !isMainFrame ? .allow : .refuse(.data)

    default:
      return .refuse(.unsupported(scheme: scheme.isEmpty ? "unknown" : scheme))
    }
  }

  /// Whether a navigation WebKit marks as a download may start. Any scheme may, so a page's own
  /// `blob:` and `data:` exports save. `javascript:` never runs, and `file:` saves nothing, even
  /// when a page marks the link as a download.
  public static func decideDownload(_ url: URL) -> SchemeDecision {
    let scheme = url.scheme?.lowercased() ?? ""

    switch scheme {
    case "javascript":
      return .refuse(.javascript)

    case "file":
      return .refuse(.file)

    case "":
      return .refuse(.unsupported(scheme: "unknown"))

    default:
      return .allow
    }
  }

  /// True for an address a typed, restored, or controller load may use. A stored address that
  /// fails this is not worth keeping, since no restore would load it.
  public static func isLoadable(_ url: URL) -> Bool {
    decide(url, source: .typed) == .allow
  }

  private static func isBlank(_ url: URL) -> Bool {
    url.absoluteString.lowercased() == "about:blank"
  }

  private static func isSrcdoc(_ url: URL) -> Bool {
    url.absoluteString.lowercased() == "about:srcdoc"
  }
}

/// An address cut for a sentence. A page chooses the addresses it links to, so a sentence that
/// names one cuts it, and the reason at the end of the sentence stays whole.
public enum AddressDisplay {
  public static let maximumCharacters = 120

  /// The most UTF-8 bytes a shown address keeps. A run of combining marks is one character, so the
  /// character bound alone leaves it unbounded.
  public static let maximumBytes = 480

  /// The address as a question, a pane, or a notice may show it. Bidirectional overrides and
  /// isolates are dropped, since they reorder the text around them. Every other control character
  /// becomes a space. The result is cut to `maximumCharacters` characters and `maximumBytes` bytes,
  /// whichever comes first, with an ellipsis.
  public static func bounded(_ address: String) -> String {
    var kept = String.UnicodeScalarView()
    var bytes = 0
    var cut = false

    for scalar in address.unicodeScalars {
      if isBidirectionalControl(scalar) { continue }

      let size = String(scalar).utf8.count

      guard bytes + size <= maximumBytes else {
        cut = true
        break
      }

      bytes += size
      kept.append(scalar.properties.generalCategory == .control ? " " : scalar)
    }

    var text = String(kept).trimmingCharacters(in: .whitespaces)

    if text.count > maximumCharacters {
      text = String(text.prefix(maximumCharacters))
      cut = true
    }

    return cut ? text + "\u{2026}" : text
  }

  private static func isBidirectionalControl(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x202A...0x202E, 0x2066...0x2069, 0x200E, 0x200F, 0x061C: return true
    default: return false
    }
  }
}
