import ControllerPackage
import ControllerTrust
import ScriptHost

/// The text of a controller's startup review. The descriptor's name and paths come from the
/// package, so each is escaped as a launch's inputs are, and no name can fake a line.
enum ControllerReviewText {
  /// Everything the review shows: who asks, what is new, and every requested power.
  static func summary(_ review: ControllerReview) -> String {
    let subject = review.identity.artifact == .file ? "Script file" : "Controller"
    var lines = [
      "\(subject): \(LaunchApprovalText.escaped(review.name)) (\(review.identity.controllerID))",
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
        "\(review.waiting.count) runs wait. Allow Once and Allow for This Run start the "
          + "oldest alone.")
    }

    if let notice = review.notice { lines.append(notice) }

    return lines.joined(separator: "\n")
  }

  /// The choices a review offers, in the order the panel shows them. Trust This Identity is
  /// offered only for a signed controller. Neither trust choice is offered when the policy file
  /// cannot take one.
  static func offered(for review: ControllerReview) -> [ControllerReviewChoice] {
    var offered: [ControllerReviewChoice] = [.allowOnce, .allowForSession]

    if review.canRemember {
      offered.append(.trustVersion)

      if review.isSigned { offered.append(.trustIdentity) }
    }

    return offered + [.deny]
  }

  /// What each offered choice covers, so the user can tell them apart before choosing. The panel's
  /// help button shows it. A choice the review does not offer is not described.
  static func choices(for review: ControllerReview) -> String {
    var sentences = [
      "Allow Once starts this run, and each later use of a power asks again.",
      "Allow for This Run gives this run these powers until it ends.",
    ]
    let shown = offered(for: review)

    if shown.contains(.trustVersion) {
      sentences.append("Trust This Version remembers them for this exact verified version.")
    }

    if shown.contains(.trustIdentity) {
      let subject = review.identity.artifact == .file ? "file" : "controller"

      sentences.append(
        "Trust This Identity remembers them for every version this key signs under this "
          + "\(subject) ID.")
    }

    if shown.contains(.trustVersion) || shown.contains(.trustIdentity) {
      sentences.append(
        "Nothing remembered overrides a disconnected pane, adopts restored panes, or chooses Run.")
    }

    return sentences.joined(separator: " ")
  }

  /// Everything the review of an undeclared file shows. The name comes from the command, so it is
  /// escaped as a descriptor's is.
  static func summary(_ review: UndeclaredReview) -> String {
    let allowed =
      review.capabilities.isEmpty
      ? "  no --allow capabilities"
      : review.capabilities.map { "  --allow \(LaunchApprovalText.escaped($0))" }
        .joined(separator: "\n")

    return [
      "Undeclared script file: \(LaunchApprovalText.escaped(review.name))",
      "It declares nothing, so uniterm cannot tell what it will do. Adding a "
        + "(declare-permissions ...) form makes it reviewable and trustable.",
      "Asks for:",
      allowed,
      "Each choice lasts this run only.",
    ].joined(separator: "\n")
  }

  /// What an undeclared run that the user admitted can do now.
  static func summary(_ run: UndeclaredRun) -> String {
    let power =
      run.choice == .allowEverything
      ? "Allow Everything: it reads and replaces the clipboard without asking. A host launch "
        + "still asks each time."
      : "Allow and Ask Each Use: its clipboard calls ask, and its pane calls follow the pane rules."

    return [
      "Undeclared script file: \(LaunchApprovalText.escaped(run.name)), process \(run.pid)",
      power,
      "Revoke ends its authority. Its next call is refused.",
    ].joined(separator: "\n")
  }

  /// What each choice of an undeclared file's review covers.
  static let undeclaredChoices =
    "Reject does not start the script. Allow and Ask Each Use starts it, and each clipboard call "
    + "asks again. Allow Everything starts it and lets it read and replace the clipboard until it "
    + "ends. A host launch always asks. None of the choices is remembered."
}
