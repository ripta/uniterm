import AppKit
import AppletKit

/// How the user left the "Open With" chooser.
public enum OpenWithOutcome: Sendable, Equatable {
  /// Open the file in this applet type.
  case open(appletTypeID: String)

  /// The user cleared the saved choice. The caller routes the file again by rank.
  case clearedSavedChoice

  case cancelled
}

/// The "Open With" chooser: a sheet or a panel that lists every applet that declares the file's
/// type, offers to remember the pick for the exact type, and clears a remembered pick.
@MainActor
public final class OpenWithChooser: NSObject {
  private let model: OpenWithModel
  private let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
  private let checkbox: NSButton

  public init(model: OpenWithModel) {
    self.model = model

    checkbox = NSButton(
      checkboxWithTitle: "Always use this for \(model.type) files", target: nil, action: nil)

    super.init()

    for candidate in model.candidates {
      popUp.addItem(withTitle: candidate.displayName)
      popUp.lastItem?.representedObject = candidate.typeID
    }

    if let index = model.candidates.firstIndex(where: { $0.typeID == model.selection }) {
      popUp.selectItem(at: index)
    }

    checkbox.state = model.alwaysUse ? .on : .off
    checkbox.isEnabled = model.canSaveChoice
  }

  /// The alert the chooser shows. The buttons are Open, Cancel, and, when a choice is stored,
  /// Clear Saved Choice.
  public func makeAlert() -> NSAlert {
    let alert = NSAlert()
    alert.messageText = "Open \u{201C}\(model.file.lastPathComponent)\u{201D} with"
    alert.informativeText = "Pick the applet that opens this file."
    alert.addButton(withTitle: "Open")
    alert.addButton(withTitle: "Cancel")

    if model.hasStoredChoice {
      alert.addButton(withTitle: "Clear Saved Choice")
    }

    let stack = NSStackView(views: [popUp, checkbox])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    stack.frame = NSRect(x: 0, y: 0, width: 280, height: 56)

    alert.accessoryView = stack
    return alert
  }

  /// Shows the chooser over `window`, or on its own when there is none, and returns what the user
  /// did. Choosing Open saves the pick when the checkbox is on.
  public func present(in window: NSWindow?) async -> OpenWithOutcome {
    let alert = makeAlert()

    let response: NSApplication.ModalResponse
    if let window {
      response = await alert.beginSheetModal(for: window)
    } else {
      response = alert.runModal()
    }

    return settle(response)
  }

  func settle(_ response: NSApplication.ModalResponse) -> OpenWithOutcome {
    switch response {
    case .alertFirstButtonReturn:
      if let id = popUp.selectedItem?.representedObject as? String {
        model.selection = id
      }

      model.alwaysUse = checkbox.state == .on
      return .open(appletTypeID: model.confirm())

    case .alertThirdButtonReturn:
      model.clearSavedChoice()
      return .clearedSavedChoice

    default:
      return .cancelled
    }
  }
}
