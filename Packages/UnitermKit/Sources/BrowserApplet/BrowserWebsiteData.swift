import BrowserModel
import Foundation
import WebKit

/// The browser's own website data: one persistent store that every browser pane shares, and the
/// list of HTTPS-only hosts that sits beside it.
///
/// The store is never WebKit's app-wide default store. The text viewer and the canvas also use
/// WebKit, so they neither share the browser's logins nor lose their data when it is cleared. The
/// host builds one of these at launch and gives its `store` to every pane it creates.
@MainActor
public final class BrowserWebsiteData {
  /// The identifier of the browser's store.
  ///
  /// This value must never change. WebKit keeps each store's data under its identifier and cannot
  /// move data between identifiers, so a new value orphans every login and all site data. The
  /// bundle identifier scopes the store too, and it must stay put for the same reason.
  public static let storeIdentifier = UUID(uuidString: "6F1B8E3A-2D4C-4A97-B05E-7C93D1A84F26")!

  /// Why a clear did not finish. Each case says what is left, so the message can tell the user.
  public enum ClearError: Error, LocalizedError, Equatable {
    /// The list of HTTPS-only hosts could not be emptied on disk. Site data is already gone.
    case hostsListKept

    /// The browser's data does not exist, so nothing could be cleared.
    case unavailable

    public var errorDescription: String? {
      switch self {
      case .unavailable:
        return "Could not clear website data. The browser has not started."

      case .hostsListKept:
        return
          "Website data was partly cleared. Cookies and site data are removed, but the list of "
          + "HTTPS-only hosts could not be emptied."
      }
    }
  }

  /// The browser's website data store.
  public let store: WKWebsiteDataStore

  private let hsts: HSTSStore

  /// A browser's data over `store`, with `hsts` as its list of HTTPS-only hosts. A test passes a
  /// store of its own. The app uses `live`.
  public init(store: WKWebsiteDataStore, hsts: HSTSStore) {
    self.store = store
    self.hsts = hsts
  }

  /// The browser's data in a running app. `identifier` is the browser's store unless a debug build
  /// names a throwaway one, and `inMemory` gives a store that keeps nothing, which a UI test uses
  /// so it never reaches the user's store.
  public static func live(
    services: BrowserServices, identifier: UUID = storeIdentifier, inMemory: Bool = false
  ) -> BrowserWebsiteData {
    BrowserWebsiteData(
      store: inMemory ? .nonPersistent() : WKWebsiteDataStore(forIdentifier: identifier),
      hsts: services.hsts)
  }

  /// Removes everything in the browser's store and empties the list of HTTPS-only hosts. No tab
  /// reloads, so an open page keeps its current session in memory until the user reloads or
  /// closes it.
  public func clear() async throws {
    await store.removeData(
      ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)

    guard hsts.removeAll() else { throw ClearError.hostsListKept }
  }
}
