import Foundation

/// An applet that opens another tab when the host asks. The terminal in shell mode and the browser
/// adopt it. The host never switches on a concrete applet type to find them.
@MainActor
public protocol TabOpening: Applet {
  /// False when the applet has tabs but cannot open another now, as a terminal that runs one
  /// program cannot.
  var canOpenTab: Bool { get }

  /// True when a tab starts in a directory. A browser tab has none, so a directory the caller
  /// names is refused for it instead of dropped.
  var tabsStartInDirectory: Bool { get }

  /// Opens a tab after the selected one and selects it. The directory is where the tab starts. Nil
  /// leaves the choice to the applet, which uses the directory the selected tab reports. Returns
  /// the new tab's ID, or nil when the tab did not open.
  @discardableResult
  func openTab(startingIn directory: String?) -> AppletTabID?

  /// Why a program may not open a tab through the generic tab open, or nil when it may. This is
  /// not the user's New Tab, which never consults it. An applet whose tabs need a power of their
  /// own, as the browser's do, names the command that opens one.
  var programOpenRefusal: String? { get }
}

extension TabOpening {
  public var programOpenRefusal: String? { nil }
}

/// An applet that keeps state for the controller that made it, such as the tabs a controller
/// opened. The state belongs to one grant. It ends with the grant, and with any change of the
/// pane's control.
@MainActor
public protocol CallerOwning: Applet {
  /// A pane the caller's layout created starts with its first tab owned by the caller.
  func adoptFirstTab(for caller: AppletCaller)

  /// The grant ended: the controller was revoked, its run ended, or it disconnected. The applet
  /// drops everything it kept for the caller.
  func grantDidEnd(_ caller: AppletCaller)
}
