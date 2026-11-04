import Foundation

/// Whether an open that arrived through Launch Services is the user's act.
public enum OpenAuthority: Sendable, Equatable {
  /// An Apple program the user drove sent the open. It needs no grant.
  case userAct(opener: String)

  /// Anyone else. The open is refused before any path is touched. `sender` names the program in a
  /// message.
  case refused(sender: String)

  /// Apple's user-facing openers are the user's act. Every other sender is refused, a sender that
  /// could not be identified included. Approvals for the others wait on the approval flow.
  public static func decide(for sender: SenderIdentity?) -> OpenAuthority {
    guard let sender else { return .refused(sender: "an unidentified program") }

    if let opener = sender.opener { return .userAct(opener: opener) }

    return .refused(sender: sender.name)
  }

  /// The message for a refusal. It names the sender and the way forward.
  public static func refusalMessage(sender: String) -> String {
    "uniterm did not open the files sent by \(sender). For now only Finder, the Dock, and "
      + "Spotlight can open files here. Use File > Open instead."
  }
}

/// Keeps refusal messages bounded. A loop of refused opens posts one message per interval, and the
/// message counts the ones it folded. State stays a few numbers, whatever the loop sends.
public struct RefusalCoalescer: Sendable {
  public let interval: TimeInterval

  private var lastPost: TimeInterval?
  private var folded = 0

  public init(interval: TimeInterval = 30) {
    self.interval = interval
  }

  /// The text to post for a refusal at `now`, or nil when an earlier message covers it.
  public mutating func note(sender: String, at now: TimeInterval) -> String? {
    if let lastPost, now - lastPost < interval, now >= lastPost {
      folded += 1
      return nil
    }

    let base = OpenAuthority.refusalMessage(sender: sender)
    let text = folded == 0 ? base : "\(base) \(folded) earlier refused opens were folded into this."

    lastPost = now
    folded = 0
    return text
  }
}
