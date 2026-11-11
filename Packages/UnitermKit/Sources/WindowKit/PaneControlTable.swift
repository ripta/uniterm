import AppletKit
import LayoutKit
import PaneModel
import ScriptHost

/// What the window asks the scripting host about controllers. The host knows which connection acts
/// for which pane. The window knows which groups each connection owns.
@MainActor
public protocol ControllerAuthority: AnyObject {
  /// The connections that act for a pane now.
  func controllers(actingFrom window: UInt64, pane: NodeID) -> Set<UInt64>

  /// Ends the control of each connection, and refuses its calls from now on.
  func revokeControllers(_ ids: Set<UInt64>)

  /// What pane chrome calls a connection, or nil when it is gone.
  func controllerName(_ id: UInt64) -> String?
}

extension ScriptHost: ControllerAuthority {}

/// The access mode of each pane of one window. The window holds it, never an applet, keyed by the
/// pane's ID. A pane with no entry is disconnected, so every new pane starts that way and a
/// reopened pane, which gets a new ID, never inherits an old mode.
///
/// Every change issues a new generation for the pane, from one counter for the window, so a
/// generation never repeats within the window.
struct PaneControlTable {
  private var access: [NodeID: PaneAccessMode] = [:]
  private var generations: [NodeID: UInt64] = [:]
  private var lastGeneration: UInt64 = 0

  /// The control each restored pane had when its layout was saved. It is shown, never applied.
  private var intents: [NodeID: SavedPaneControl] = [:]

  func control(of pane: NodeID) -> PaneControl {
    PaneControl(
      access: access[pane] ?? .disconnected, driver: .none, generation: generations[pane] ?? 0)
  }

  func intent(of pane: NodeID) -> SavedPaneControl? {
    intents[pane]
  }

  /// Sets the pane's mode and issues it a new generation. Returns the new control.
  mutating func set(_ mode: PaneAccessMode, for pane: NodeID) -> PaneControl {
    access[pane] = mode == .disconnected ? nil : mode
    intents[pane] = nil

    return bump(pane)
  }

  /// Issues the pane a new generation and keeps its mode. Anything asked under the old generation
  /// is stale.
  mutating func bump(_ pane: NodeID) -> PaneControl {
    lastGeneration += 1
    generations[pane] = lastGeneration

    return control(of: pane)
  }

  mutating func remember(_ intent: SavedPaneControl, for pane: NodeID) {
    intents[pane] = intent == .disconnected ? nil : intent
  }

  /// Drops a pane that left the tree. Its ID is retired, so nothing can name it again.
  mutating func forget(_ pane: NodeID) {
    access[pane] = nil
    generations[pane] = nil
    intents[pane] = nil
  }
}
