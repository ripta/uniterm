import Foundation
import Preferences
import StatusKit

/// Where one window's command palette lives: floating, or docked against an edge.
///
/// Both settings follow the same rule as the status bar position. A value that is not one of the
/// choices falls back to the default. The window says so once in its own status bar. The stored
/// value is never rewritten.
@MainActor
final class PalettePlacement {
  /// The palette's mode and, for a docked palette, its edge.
  struct Value: Equatable {
    var mode: PaletteMode
    var edge: DockEdge
  }

  private(set) var value: Value

  /// Runs when either setting changes. It does not run for the first reading.
  var onChange: ((Value) -> Void)?

  private let store: SettingsStore
  private let statusCenter: StatusCenter
  private var observation: SettingsObservation?
  private var warnedMode: String?
  private var warnedEdge: String?

  init(store: SettingsStore, statusCenter: StatusCenter) {
    self.store = store
    self.statusCenter = statusCenter

    let mode = store.reading(of: .paletteMode)
    let edge = store.reading(of: .paletteDockEdge)
    value = Value(mode: mode.value, edge: DockEdge(edge.value))

    store.watch(.paletteMode)
    store.watch(.paletteDockEdge)
    observation = store.addObserver { [weak self] in self?.refresh() }

    warn(mode, name: "palette mode", warned: &warnedMode)
    warn(edge, name: "palette edge", warned: &warnedEdge)
  }

  isolated deinit {
    observation?.cancel()
  }

  private func refresh() {
    let mode = store.reading(of: .paletteMode)
    let edge = store.reading(of: .paletteDockEdge)

    warn(mode, name: "palette mode", warned: &warnedMode)
    warn(edge, name: "palette edge", warned: &warnedEdge)

    let next = Value(mode: mode.value, edge: DockEdge(edge.value))

    guard next != value else { return }

    value = next
    onChange?(next)
  }

  /// Every watched setting wakes this observer, so a warning waits for a new invalid value.
  private func warn<Choice: RawRepresentable>(
    _ reading: SettingReading<Choice>, name: String, warned: inout String?
  ) where Choice.RawValue == String, Choice: Sendable {
    guard case .invalid(let raw, let fallback) = reading else {
      warned = nil
      return
    }

    guard raw != warned else { return }

    warned = raw
    statusCenter.post(
      level: .warning,
      text:
        "The \(name) \u{201C}\(StatusBarPlacement.quoted(raw))\u{201D} is not valid. Using \(fallback.rawValue)."
    )
  }
}
