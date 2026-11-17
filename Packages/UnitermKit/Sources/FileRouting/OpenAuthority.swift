import Foundation

/// Whether an open that arrived through Launch Services is the user's act.
public enum OpenAuthority: Sendable, Equatable {
  /// An Apple program the user drove sent the open. It needs no grant.
  case userAct(opener: String)

  /// Anyone else. The open waits for the user's answer, and nothing touches a path before it.
  /// `sender` is nil when the sender could not be identified. `onceOnly` says the answer can cover
  /// this event and no other, since nothing the user could name would stay the same sender.
  case needsApproval(sender: SenderIdentity?, onceOnly: Bool)

  /// Apple's user-facing openers are the user's act. Every other sender needs approval.
  ///
  /// A sender that could not be identified, and an Apple-signed program that is not an opener,
  /// get Allow once only. The first could be any program. The second is a go-between such as
  /// `/usr/bin/open`, `osascript`, or `python3`, which any program can drive, so a session grant
  /// on it would cover whoever happens to be using it. A sender with no signing identifier cannot
  /// be named in the question, so it is treated as unidentified.
  public static func decide(for sender: SenderIdentity?) -> OpenAuthority {
    guard let sender else { return .needsApproval(sender: nil, onceOnly: true) }

    if let opener = sender.opener { return .userAct(opener: opener) }

    let named = sender.signingIdentifier?.isEmpty == false

    return .needsApproval(sender: sender, onceOnly: sender.isAppleAnchored || !named)
  }

  /// Why an open that needed approval did not open.
  public enum Refusal: Sendable, Equatable {
    /// Too many questions wait for the user.
    case busy

    /// The user denied it.
    case denied

    /// The sender quit before the user answered.
    case withdrawn

    /// The event named no local file, so there was nothing to ask about.
    case noLocalFiles

    fileprivate var because: String {
      switch self {
      case .busy:
        return "too many questions wait for you. Answer them in Window > Pending Requests, or "
          + "use File > Open"

      case .denied:
        return "you denied it"

      case .withdrawn:
        return "it quit before you answered"

      case .noLocalFiles:
        return "none of them is a local file"
      }
    }
  }

  /// The message for a refusal. It names the sender and says why.
  public static func refusalMessage(sender: String, reason: Refusal) -> String {
    "uniterm did not open the files sent by \(sender), since \(reason.because)."
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
  public mutating func note(
    sender: String, reason: OpenAuthority.Refusal, at now: TimeInterval
  ) -> String? {
    if let lastPost, now - lastPost < interval, now >= lastPost {
      folded += 1
      return nil
    }

    let base = OpenAuthority.refusalMessage(sender: sender, reason: reason)
    let text = folded == 0 ? base : "\(base) \(folded) earlier refused opens were folded into this."

    lastPost = now
    folded = 0
    return text
  }
}
