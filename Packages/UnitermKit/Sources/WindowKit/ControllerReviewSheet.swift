import AppKit
import ControllerPackage
import ControllerTrust
import ScriptHost

/// The text of a controller's startup review. The descriptor's name and paths come from the
/// package, so each is escaped as a launch's inputs are, and no name can fake a line.
enum ControllerReviewText {
  /// Everything the review shows: who asks, what is new, and every requested power.
  static func summary(_ review: ControllerReview) -> String {
    var lines = [
      "Controller: \(LaunchApprovalText.escaped(review.name)) (\(review.identity.controllerID))",
      "Version: \(review.identity.version)",
      review.identity.keyFingerprint.map { "Signed by key: \($0)" }
        ?? "Unsigned: only this exact version can be trusted.",
    ]

    if review.revises != nil, !review.added.isEmpty {
      lines.append("New since you trusted it:")
      lines += review.added.map { "  + \(LaunchApprovalText.escaped($0.displayText))" }
    }

    lines.append("Asks for:")
    lines += review.requested.map { "  \(LaunchApprovalText.escaped($0.displayText))" }

    if review.waiting.count > 1 {
      lines.append(
        "\(review.waiting.count) runs wait. Allow Once and Allow for This Session start the "
          + "oldest alone.")
    }

    if let notice = review.notice { lines.append(notice) }

    return lines.joined(separator: "\n")
  }

  /// What each choice the sheet shows covers, so the user can tell them apart before choosing.
  /// A choice the sheet leaves out is not described.
  static func choices(for review: ControllerReview) -> String {
    var sentences = [
      "Allow Once starts this run, and each later use of a power asks again.",
      "Allow for This Session gives this run these powers until it ends.",
    ]
    let shown = ControllerReviewSheet.options(for: review).map(\.choice)

    if shown.contains(.trustVersion) {
      sentences.append("Trust This Version remembers them for this exact verified version.")
    }

    if shown.contains(.trustIdentity) {
      sentences.append(
        "Trust This Identity remembers them for every version this key signs under this "
          + "controller ID.")
    }

    if shown.contains(.trustVersion) || shown.contains(.trustIdentity) {
      sentences.append(
        "Nothing remembered overrides a disconnected pane, adopts restored panes, or chooses Run.")
    }

    return sentences.joined(separator: " ")
  }
}

/// The sheet that answers a startup review. Deny is the default button, so a stray Return grants
/// nothing. Trust This Identity is offered only for a signed controller, and neither trust choice
/// is offered when the policy file cannot take one.
@MainActor
enum ControllerReviewSheet {
  /// The buttons, in order, with each one's accessibility identifier and answer.
  nonisolated static func options(for review: ControllerReview) -> [(
    title: String, identifier: String, choice: ControllerReviewChoice
  )] {
    var options: [(title: String, identifier: String, choice: ControllerReviewChoice)] = [
      ("Deny", "controller-review-deny", .deny),
      ("Allow Once", "controller-review-once", .allowOnce),
      ("Allow for This Session", "controller-review-session", .allowForSession),
    ]

    if review.canRemember {
      options.append(("Trust This Version", "controller-review-version", .trustVersion))

      if review.isSigned {
        options.append(("Trust This Identity", "controller-review-identity", .trustIdentity))
      }
    }

    return options
  }

  /// How wide the summary is. The alert takes its width from it, so it is wide enough for a
  /// 64-character version on one line and for every button in one row.
  private static let summaryWidth: CGFloat = 580

  /// The summary, left-aligned so its indented power lines read as a list. An alert centers its
  /// own text, which would hide the indent.
  private static func summaryView(_ review: ControllerReview) -> NSView {
    let text = NSTextField(wrappingLabelWithString: ControllerReviewText.summary(review))

    text.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    text.alignment = .left
    text.isSelectable = true
    text.preferredMaxLayoutWidth = summaryWidth
    text.setAccessibilityIdentifier("controller-review-summary")
    text.setFrameSize(NSSize(width: summaryWidth, height: text.fittingSize.height))

    return text
  }

  static func present(_ review: ControllerReview, on window: NSWindow?) async
    -> ControllerReviewChoice?
  {
    let alert = NSAlert()
    let options = options(for: review)
    let choices = options.map(\.choice)

    alert.alertStyle = .warning
    alert.messageText = "Allow \(LaunchApprovalText.escaped(review.name)) to start?"
    alert.informativeText = ControllerReviewText.choices(for: review)
    alert.accessoryView = summaryView(review)
    alert.window.setAccessibilityIdentifier("controller-review")

    for option in options {
      alert.addButton(withTitle: option.title).setAccessibilityIdentifier(option.identifier)
    }

    alert.buttons[0].keyEquivalent = "\r"

    for button in alert.buttons.dropFirst() { button.keyEquivalent = "" }

    let response: NSApplication.ModalResponse

    if let window, window.isVisible {
      response = await alert.beginSheetModal(for: window)
    } else {
      response = alert.runModal()
    }

    let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue

    return choices.indices.contains(index) ? choices[index] : nil
  }
}
