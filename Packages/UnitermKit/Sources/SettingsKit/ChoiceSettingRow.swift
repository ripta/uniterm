import AppKit
import Preferences

/// One row of the Settings form for a setting with a few named values. It supplies the caption and
/// the control, and the form lays them out in its columns. A change writes the setting at once. A
/// change from outside the window, such as `defaults write`, updates the control. A stored value
/// this version does not know shows the default and says so in a note under the control. The row
/// never writes the stored value back.
@MainActor
final class ChoiceSettingRow<
  Value: RawRepresentable & CaseIterable & Equatable & Sendable
>: NSObject
where Value.RawValue == String, Value.AllCases: RandomAccessCollection, Value.AllCases.Index == Int
{
  let label: NSTextField
  let control = NSSegmentedControl()

  /// Says that the stored value was replaced. It is hidden, and takes no room, while the stored
  /// value is one this version knows.
  let note = NSTextField(wrappingLabelWithString: "")

  /// The control and its note, which is what the form puts in its second column.
  let cell = NSStackView()

  private let store: SettingsStore
  private let key: SettingKey<Value>
  private let title: (Value) -> String
  private var observation: SettingsObservation?

  init(
    store: SettingsStore, key: SettingKey<Value>, caption: String, identifier: String,
    title: @escaping (Value) -> String
  ) {
    self.store = store
    self.key = key
    self.title = title
    label = NSTextField(labelWithString: caption)
    super.init()

    control.segmentCount = Value.allCases.count
    control.trackingMode = .selectOne
    for (index, value) in Value.allCases.enumerated() {
      control.setLabel(title(value), forSegment: index)
    }
    control.target = self
    control.action = #selector(selectionChanged(_:))
    control.setAccessibilityIdentifier(identifier)

    note.font = .preferredFont(forTextStyle: .caption1)
    note.textColor = .secondaryLabelColor
    note.isHidden = true
    note.preferredMaxLayoutWidth = 320
    note.setAccessibilityIdentifier(identifier + "-note")

    cell.orientation = .vertical
    cell.alignment = .leading
    cell.spacing = 4
    cell.setViews([control, note], in: .leading)

    store.watch(key)
    observation = store.addObserver { [weak self] in self?.syncFromStore() }
    syncFromStore()
  }

  isolated deinit {
    observation?.cancel()
  }

  @objc private func selectionChanged(_ sender: NSSegmentedControl) {
    let index = sender.selectedSegment
    guard Value.allCases.indices.contains(index) else { return }

    store.set(Value.allCases[index], for: key)
  }

  private func syncFromStore() {
    let reading = store.reading(of: key)
    let current = reading.value

    if case .invalid(let raw, let fallback) = reading {
      note.stringValue =
        "\u{201C}\(raw)\u{201D} is not a choice this version has. Using \(title(fallback))."
      note.isHidden = false
    } else {
      note.stringValue = ""
      note.isHidden = true
    }

    if let index = Value.allCases.firstIndex(of: current) {
      control.selectedSegment = index
    }
  }
}
