import AppKit
import AppletKit

/// Shows a permission request and returns the user's answer. Tests replace it.
public typealias PermissionAsker =
  @MainActor (_ request: AppletPermissionRequest, _ window: NSWindow?) async ->
  AppletPermissionAnswer

public enum PermissionDialog {
  /// Asks in a sheet on the window, or in a modal alert when the window is not on screen. Deny is
  /// the default button, so a stray Return grants nothing.
  @MainActor
  public static let present: PermissionAsker = { request, window in
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = request.title
    alert.informativeText = request.detail
    alert.addButton(withTitle: "Deny")
    alert.addButton(withTitle: "Allow Once")
    alert.addButton(withTitle: request.sessionTitle)
    alert.buttons[0].keyEquivalent = "\r"
    alert.buttons[1].keyEquivalent = ""
    alert.buttons[2].keyEquivalent = ""
    alert.window.setAccessibilityIdentifier("permission-request")

    let response: NSApplication.ModalResponse
    if let window, window.isVisible {
      response = await alert.beginSheetModal(for: window)
    } else {
      response = alert.runModal()
    }

    switch response {
    case .alertSecondButtonReturn: return .allowOnce
    case .alertThirdButtonReturn: return .allowForSession
    default: return .deny
    }
  }
}
