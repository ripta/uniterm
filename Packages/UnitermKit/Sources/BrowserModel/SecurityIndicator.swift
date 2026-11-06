import Foundation

/// When the address bar shows its warning icon.
///
/// WebKit reports whether every resource of the current page came over a secure connection. The
/// indicator adds two rules on top. A blank page has nothing to warn about. An `http` page always
/// warns, whatever the flag says. WebKit moves `url` to a new page before it updates the flag, so
/// during a load the flag can still describe the page the user left. A `blob:` page made by an
/// `http` page warns through the flag, which WebKit reports for the page's origin.
public enum SecurityIndicator {
  /// Whether `url` is the empty page, with or without a query or fragment. The address bar shows
  /// no address for it.
  public static func isBlank(_ url: URL) -> Bool {
    // Read the string. The path of an opaque URL differs between Swift's `URL` and the `NSURL`
    // that WebKit returns.
    let head = url.absoluteString.prefix { $0 != "#" && $0 != "?" }

    return head.lowercased() == "about:blank"
  }

  /// Whether the page at `url` should show the warning. `hasOnlySecureContent` is WebKit's flag
  /// for the page. A tab that never loaded has no URL, and never warns.
  public static func warns(url: URL?, hasOnlySecureContent: Bool) -> Bool {
    guard let url, !isBlank(url) else { return false }

    if url.scheme?.lowercased() == "http" { return true }

    return !hasOnlySecureContent
  }
}
