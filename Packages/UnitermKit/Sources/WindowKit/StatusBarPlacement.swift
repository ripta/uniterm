import Foundation
import Preferences
import StatusKit

/// Follows the status bar position setting for one window.
///
/// A value that is not a position falls back to the default. The window says so once in its own
/// status bar. The stored value is never rewritten, so the user's text stays for them to fix.
@MainActor
final class StatusBarPlacement {
  /// The longest piece of a stored value that a warning repeats.
  static let maximumQuotedLength = 40

  private(set) var position: StatusBarPosition

  /// Runs when the position changes. It does not run for the first reading.
  var onChange: ((StatusBarPosition) -> Void)?

  private let store: SettingsStore
  private let statusCenter: StatusCenter
  private var observation: SettingsObservation?
  private var warnedRaw: String?

  init(store: SettingsStore, statusCenter: StatusCenter) {
    self.store = store
    self.statusCenter = statusCenter

    let reading = store.reading(of: .statusBarPosition)
    position = reading.value

    store.watch(.statusBarPosition)
    observation = store.addObserver { [weak self] in self?.refresh() }

    warnIfInvalid(reading)
  }

  isolated deinit {
    observation?.cancel()
  }

  private func refresh() {
    let reading = store.reading(of: .statusBarPosition)
    warnIfInvalid(reading)

    guard reading.value != position else { return }

    position = reading.value
    onChange?(position)
  }

  /// Every watched setting wakes this observer, so the warning waits for a new invalid value. A
  /// theme change must not repeat it.
  private func warnIfInvalid(_ reading: SettingReading<StatusBarPosition>) {
    guard case .invalid(let raw, let fallback) = reading else {
      warnedRaw = nil
      return
    }

    guard raw != warnedRaw else { return }

    warnedRaw = raw
    statusCenter.post(
      level: .warning,
      text:
        "The status bar position \u{201C}\(Self.quoted(raw))\u{201D} is not valid. Using \(fallback.rawValue)."
    )
  }

  /// The stored text comes from outside the app. It must not forge a second line.
  static func quoted(_ raw: String) -> String {
    let flat = raw.unicodeScalars.map { scalar -> Character in
      CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar)
        ? " " : Character(scalar)
    }

    return String(String(flat).prefix(maximumQuotedLength))
  }
}
