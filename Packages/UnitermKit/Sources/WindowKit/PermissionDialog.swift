import AppKit
import AppletKit

/// Answers a permission request in place of the Pending Requests panel. Only tests set one.
public typealias PermissionAsker =
  @MainActor (_ request: AppletPermissionRequest, _ window: NSWindow?) async ->
  AppletPermissionAnswer
