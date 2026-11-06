import AppKit
import Preferences

/// The Settings window, opened with Cmd-,. It is an AppKit window. SwiftUI forms may join it later
/// as leaf views.
@MainActor
public final class SettingsWindowController: NSWindowController {
  /// `clearWebsiteData` removes the browser's stored data. It comes from the host, since this module
  /// links no web engine. It throws when it cannot finish, and the row says so.
  public init(
    store: SettingsStore, clearWebsiteData: @escaping @MainActor () async throws -> Void
  ) {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false)
    window.title = "Settings"
    window.isReleasedWhenClosed = false
    window.isRestorable = false
    window.setAccessibilityIdentifier("settings-window")
    window.contentViewController = SettingsViewController(
      store: store, clearWebsiteData: clearWebsiteData)
    window.center()

    super.init(window: window)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  public func present() {
    NSApp.activate()
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
  }
}
