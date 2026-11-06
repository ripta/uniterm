import Foundation

/// The restorable state of a browser pane.
///
/// It is inert. Each tab holds the last committed URL and title, and one tab is selected. It holds
/// no back or forward history, no form data, and no website data. The payload has a tab array and a
/// selected tab from the first version, so adding tabs to the pane needs no version bump.
///
/// The applet wraps this in the layout file's description envelope. This type has no AppKit and
/// no applet types, so its rules test on their own.
public struct BrowserDescription: Codable, Equatable, Sendable {
  public static let typeID = "browser"

  /// The version of the payload this build reads and writes. A change an older build cannot
  /// round-trip bumps it.
  public static let currentVersion = 1

  /// The longest title kept. A page chooses its title, and the layout file holds it.
  public static let maximumTitleCharacters = 512

  /// The longest URL kept, in UTF-8 bytes. A longer one is not stored.
  public static let maximumURLBytes = 32 * 1024

  public struct Tab: Codable, Equatable, Sendable {
    /// The last committed URL. Nil for a tab that has loaded nothing.
    public var url: String?

    public var title: String?

    public init(url: String? = nil, title: String? = nil) {
      self.url = url
      self.title = title
    }
  }

  public var tabs: [Tab]

  /// The index of the selected tab in `tabs`.
  public var selected: Int

  public init(tabs: [Tab] = [Tab()], selected: Int = 0) {
    self.tabs = tabs
    self.selected = selected
  }

  /// Why a payload was not accepted. The caller keeps the original bytes.
  public enum Failure: Error, Equatable {
    case newerVersion(found: Int, supported: Int)
    case corrupt(String)
  }

  /// Checks the version and the shape of a payload this build decoded. Only version 1 exists. A
  /// later version is refused so its bytes survive a round trip. A version below 1 never existed.
  public func validated(version: Int) throws(Failure) -> BrowserDescription {
    guard version <= Self.currentVersion else {
      throw .newerVersion(found: version, supported: Self.currentVersion)
    }

    guard version >= 1 else {
      throw .corrupt("browser description has version \(version)")
    }

    guard !tabs.isEmpty else {
      throw .corrupt("browser description has no tab")
    }

    guard tabs.indices.contains(selected) else {
      throw .corrupt("browser description selects tab \(selected) of \(tabs.count)")
    }

    return self
  }

  /// A title cut to the bound, or nil when empty.
  public static func boundedTitle(_ title: String?) -> String? {
    guard let title, !title.isEmpty else { return nil }

    return String(title.prefix(maximumTitleCharacters))
  }

  /// The string to store for a committed URL. Nil when the URL is one no restore would load, or one
  /// over the bound, and the caller then keeps what it held.
  public static func storableURL(_ url: URL?) -> String? {
    guard let url, SchemePolicy.isLoadable(url) else { return nil }

    let text = url.absoluteString

    return text.utf8.count <= maximumURLBytes ? text : nil
  }
}
