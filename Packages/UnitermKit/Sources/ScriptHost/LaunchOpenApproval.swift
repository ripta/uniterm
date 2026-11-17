import FileRouting
import Foundation

/// The words of the question for an open that another program sent through Launch Services.
public enum LaunchOpenApprovalText {
  /// The sender as the row names it. It comes from verified signing information, never from a
  /// path or a display name the sender controls.
  public static func subject(sender: SenderIdentity?) -> String {
    sender?.approvalLabel ?? "an unknown program"
  }

  /// `skipped` counts the items that are not local files and will not open. `onceOnly` says the
  /// answer covers this request only.
  public static func detail(
    paths: [String], skipped: Int, sender: SenderIdentity?, onceOnly: Bool
  ) -> String {
    let list = paths.map { "  \(OpenApprovalText.display($0))" }.joined(separator: "\n")
    let count = paths.count == 1 ? "this path" : "these \(paths.count) paths"

    let lead: String

    if let sender {
      lead = "The program \u{201C}\(sender.approvalLabel)\u{201D} asks to open \(count)"
    } else {
      lead =
        "An unknown program asks to open \(count). It may have quit already, and uniterm cannot "
        + "tell which program it was"
    }

    let tail: String

    if !onceOnly {
      tail =
        "Allow Until This App Quits lets everything this app sends open files without asking, "
        + "until it quits."
    } else if sender?.isAppleAnchored == true {
      tail =
        "This is an Apple program that other programs can drive, so this answer covers this "
        + "request only."
    } else {
      tail = "This answer covers this request only."
    }

    let skip =
      skipped == 0
      ? ""
      : "\(skipped) more \(skipped == 1 ? "item is" : "items are") not a local file and "
        + "will not open.\n"

    let place =
      "each in a new pane. A new window opens when a batch or a lack of room calls for one"

    return "\(lead), \(place):\n\(list)\n\(skip)uniterm has not looked at them yet. \(tail)"
  }

  public static let sessionTitle = "Allow Until This App Quits"
}
