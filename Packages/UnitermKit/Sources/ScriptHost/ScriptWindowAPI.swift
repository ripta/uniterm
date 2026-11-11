import Foundation
import PaneModel
import ScriptWire

/// Why a host function did not do what a script asked. The kind tells the script's mistake from a
/// refusal. The text reaches the script as the message of a Janet error, so it never names a pane
/// other than the one the script gave.
public struct ScriptCallError: Error, Equatable, Sendable {
  public let kind: ScriptFailureKind
  public let text: String

  public init(_ kind: ScriptFailureKind, _ text: String) {
    self.kind = kind
    self.text = text
  }

  public static func badArgument(_ text: String) -> ScriptCallError {
    ScriptCallError(.badArgument, text)
  }

  public static func refused(_ text: String) -> ScriptCallError {
    ScriptCallError(.refused, text)
  }

  public static func notFound(_ text: String) -> ScriptCallError {
    ScriptCallError(.notFound, text)
  }

  public static func failed(_ text: String) -> ScriptCallError {
    ScriptCallError(.failed, text)
  }

  public static func unsupported(_ text: String) -> ScriptCallError {
    ScriptCallError(.unsupported, text)
  }
}

/// Who makes a call: the connection, and the pane it acts for. The host derives both from the
/// connection's binding, never from anything the script sends. A connection acts for one pane.
public struct ScriptCaller: Sendable, Equatable {
  public let connection: UInt64
  public let window: UInt64
  public let pane: NodeID

  public init(connection: UInt64, window: UInt64, pane: NodeID) {
    self.connection = connection
    self.window = window
    self.pane = pane
  }
}

/// What the window layer offers scripts. The window layer implements it, and the app hands it to
/// the host, so this target never depends on windows.
///
/// Every function runs on the main actor and never blocks it. The two that check a directory on
/// disk are async, so the check runs off the main actor.
///
/// Every function that names a target checks the caller's authority over it. A caller reaches only
/// its own window. It may address its own pane while that pane is remote-controlled, and the
/// members of groups it owns while they are. A target outside that scope throws `notFound`, the
/// same as one that is not open, so it gives away no data. A caller whose own pane is
/// disconnected and that owns no group gets a refusal that says how the user enables the pane. A
/// caller that owns a group is not refused that way. It keeps its remote-controlled members, and a
/// target outside its scope is not found.
@MainActor
public protocol ScriptWindowAPI: AnyObject {
  /// The caller's own window, with the pane it acts for and that pane's control.
  func listWindows(caller: ScriptCaller) throws -> ScriptValue

  /// The panes of the caller's window that the caller may address, or nil for any other window.
  func listPanes(window: UInt64, caller: ScriptCaller) throws -> ScriptValue

  /// Splits `beside` and starts the applet `kind` in the new pane, in the caller's group. The
  /// directory is where the new pane starts, or nil for the one the pane beside it reports. The
  /// new pane starts with `access`, which the applet type must support.
  ///
  /// The caller's authority can end while the directory is checked. `stillAllowed` runs after
  /// that wait and before anything changes, and a throw from it stops the call. The target is
  /// resolved and checked again after it too.
  func openPane(
    kind: String, beside: ScriptTarget, axis: ScriptAxis?, directory: String?,
    access: ScriptPaneAccess, caller: ScriptCaller, stillAllowed: @MainActor () throws -> Void
  ) async throws -> ScriptValue

  /// Opens a tab in a pane whose applet has tabs. The directory is where the tab starts, or nil
  /// for the one the pane reports. `stillAllowed` runs as it does for `openPane`.
  func openTab(
    pane: ScriptTarget, directory: String?, caller: ScriptCaller,
    stillAllowed: @MainActor () throws -> Void
  ) async throws -> ScriptValue

  /// True while the pane the reference names is open. The host asks before it keeps a file for a
  /// pane, and again to find the files of panes that have closed.
  func isOpen(_ pane: ScriptPaneReference) -> Bool

  /// Resolves the target of a send and throws when the caller may not send to it, or it cannot
  /// take sent content. The host asks before it writes the content, so a refusal leaves nothing
  /// behind. The answer names the pane `send` then takes.
  func prepareSend(to target: ScriptTarget, caller: ScriptCaller) throws -> ScriptPaneReference

  /// Hands a file the app wrote to the pane's applet, which reads it like any file it opens. The
  /// host calls it right after `prepareSend`, with nothing suspended between them.
  func send(to pane: ScriptPaneReference, file: URL, caller: ScriptCaller) throws -> ScriptValue

  /// Sends one applet command to a pane through the window's shared dispatch, and returns the
  /// applet's reply. The arguments are JSON text. The command waits its turn in the queue, and
  /// `stillAllowed` runs again as it is delivered, so a grant that ends meanwhile leaves no effect.
  /// An error leaves the applet unchanged.
  func sendCommand(
    to target: ScriptTarget, appletType: String, schemaVersion: UInt32, command: String,
    arguments: String, caller: ScriptCaller, stillAllowed: @escaping @MainActor () throws -> Void
  ) async throws -> ScriptValue
}
