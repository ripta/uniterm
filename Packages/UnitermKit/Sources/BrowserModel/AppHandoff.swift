import Foundation

/// The rule for an address that names another app instead of a page, such as `mailto:` or `ssh:`.
///
/// Nothing in a page opens an app on its own. The user's own typed `mailto:` address opens the mail
/// app, since a draft still needs the user to send it. Every other scheme asks first, naming the app
/// and the address, because an app's URL handler can be exploited and the sender chooses its
/// arguments.
public enum AppHandoff {
  /// Schemes the browser never hands to an app. The page schemes load, and the refused ones never
  /// do. `about` and `blob` are not apps' to take.
  private static let notHandedOff: Set<String> = [
    "http", "https", "about", "blob", "data", "file", "javascript",
  ]

  public static func mayHandOff(scheme: String) -> Bool {
    let scheme = scheme.lowercased()

    return !scheme.isEmpty && scheme != "unknown" && !notHandedOff.contains(scheme)
  }

  /// True when the app opens without a question.
  public static func opensWithoutAsking(_ url: URL) -> Bool {
    url.scheme?.lowercased() == "mailto"
  }

  public static func question(appName: String, url: URL) -> (title: String, detail: String) {
    (
      title: "Open \(appName)?",
      detail:
        "The address \u{201C}\(AddressDisplay.bounded(url.absoluteString))\u{201D} opens "
        + "\(appName), outside the browser. Open it only if you expect that."
    )
  }

  public static func noAppMessage(for url: URL) -> String {
    let scheme = url.scheme?.lowercased() ?? "unknown"

    return
      "Did not open \(AddressDisplay.bounded(url.absoluteString)). No app handles \(scheme): addresses."
  }
}
