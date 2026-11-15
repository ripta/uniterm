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
      "Allow for This Session gives this run these powers until it ends.",
    ]
    let shown = offered(for: review)

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
