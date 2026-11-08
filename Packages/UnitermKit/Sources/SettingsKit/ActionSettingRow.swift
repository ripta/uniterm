import AppKit

/// One row of the Settings form for an action that takes a while and may fail. It supplies the
/// caption, a button, a standing note, and a line that reports how the last run went.
///
/// The button is disabled while a run is in flight, and a second run never starts beside it. A run
/// that fails says so in the row. It never reads as a success, and it never asks a question. The
/// error chooses the whole failure line, so it can say what was done and what was not. The action
/// itself comes from the host as a closure, so this module links nothing the action needs.
@MainActor
final class ActionSettingRow: NSObject {
  /// How the last run went. The row starts idle.
  enum State: Equatable {
    case idle
    case running
    case succeeded
    case failed(String)
  }

  let label: NSTextField
  let button: NSButton

  /// Reports the outcome. It is hidden, and takes no room, until a run starts.
  let status = NSTextField(wrappingLabelWithString: "")

  /// What the action leaves alone, said before and after the run.
  let note: NSTextField

  /// The button, the outcome, and the note, which is what the form puts in its second column.
  let cell = NSStackView()

  private(set) var state = State.idle

  private let action: @MainActor () async throws -> Void
  private let succeededText: String

  /// The run in flight, kept so a test can wait for it and the row can end it with the window.
  private(set) var running: Task<Void, Never>?

  init(
    caption: String, buttonTitle: String, note noteText: String, succeededText: String,
    identifier: String, action: @escaping @MainActor () async throws -> Void
  ) {
    label = NSTextField(labelWithString: caption)
    button = NSButton(title: buttonTitle, target: nil, action: nil)
    note = NSTextField(wrappingLabelWithString: noteText)
    self.action = action
    self.succeededText = succeededText
    super.init()

    button.bezelStyle = .rounded
    button.target = self
    button.action = #selector(clicked)
    button.setAccessibilityIdentifier(identifier + "-button")

    status.font = .preferredFont(forTextStyle: .caption1)
    status.preferredMaxLayoutWidth = 320
    status.isHidden = true
    status.setAccessibilityIdentifier(identifier + "-status")

    note.font = .preferredFont(forTextStyle: .caption1)
    note.textColor = .secondaryLabelColor
    note.preferredMaxLayoutWidth = 320
    note.setAccessibilityIdentifier(identifier + "-note")

    cell.orientation = .vertical
    cell.alignment = .leading
    cell.spacing = 4
    cell.setViews([button, status, note], in: .leading)
  }

  isolated deinit {
    running?.cancel()
  }

  @objc private func clicked() {
    perform()
  }

  /// Starts a run unless one is in flight. The button is disabled while one is, so a click never
  /// reaches here twice. The guard covers every other caller.
  func perform() {
    guard state != .running else { return }

    show(.running)

    running = Task { [weak self, action] in
      let outcome: State

      do {
        try await action()
        outcome = .succeeded
      } catch {
        outcome = .failed(error.localizedDescription)
      }

      self?.show(outcome)
    }
  }

  private func show(_ next: State) {
    state = next

    button.isEnabled = next != .running
    status.isHidden = next == .idle

    switch next {
    case .idle:
      status.stringValue = ""

    case .running:
      status.stringValue = "Working\u{2026}"
      status.textColor = .secondaryLabelColor

    case .succeeded:
      status.stringValue = succeededText
      status.textColor = .labelColor

    case .failed(let reason):
      status.stringValue = reason
      status.textColor = .systemRed
    }

    status.setAccessibilityValue(status.stringValue)

    if next != .idle {
      NSAccessibility.post(
        element: status, notification: .announcementRequested,
        userInfo: [
          .announcement: status.stringValue,
          .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }
  }
}
