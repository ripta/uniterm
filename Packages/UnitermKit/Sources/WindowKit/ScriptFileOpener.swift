import AppKit
import Foundation
import PaneModel
import ScriptHost

/// The window side of `uniterm open`. The host calls it only for a request the user allowed, so
/// nothing here asks again.
///
/// A path stays a string until this point, and the URL is built without asking the file system, so
/// the first look at a path is the router's own, after the approval.
@MainActor
public final class ScriptFileOpener: ScriptFileOpening {
  private let windows: WindowSet
  private let coordinator: LaunchOpenCoordinator

  public init(windows: WindowSet, coordinator: LaunchOpenCoordinator) {
    self.windows = windows
    self.coordinator = coordinator
  }

  /// A command in a terminal session anchors to that session's pane. A command in none anchors to
  /// the focused pane of the most recently key window, which the coordinator falls back to.
  public func open(_ paths: [String], from caller: ScriptCaller?) {
    let urls = paths.map { URL(fileURLWithPath: $0, isDirectory: false) }

    coordinator.receiveProgramOpen(urls) { [weak windows] in
      guard let caller, let controller = windows?.controller(forScriptWindow: caller.window),
        controller.contains(pane: caller.pane)
      else { return nil }

      return RouteAnchor(controller: controller, pane: caller.pane)
    }
  }

  public func label(of caller: ScriptCaller) -> String? {
    guard let controller = windows.controller(forScriptWindow: caller.window),
      let applet = controller.paneArea.applet(for: caller.pane)
    else { return nil }

    return applet.title
  }
}
