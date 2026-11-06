import Foundation

/// Reads the sender of an open-documents Apple Event.
public enum OpenEventSender {
  /// The audit token of the process that sent the event, as `keySenderAuditTokenAttr` carries it.
  static let senderKeyword: AEKeywordCode = 0x746F_6B6E

  /// The audit token of the process the event is attributed to when it was sent on another's
  /// behalf, as `keyActualSenderAuditToken` carries it.
  static let actualKeyword: AEKeywordCode = 0x6163_6174

  public typealias AEKeywordCode = UInt32

  /// The tokens an event carries. Either is nil when the event lacks it or it is malformed.
  public struct Tokens: Sendable, Equatable {
    public let sender: AuditToken?
    public let actual: AuditToken?

    public init(sender: AuditToken?, actual: AuditToken?) {
      self.sender = sender
      self.actual = actual
    }
  }

  public static func tokens(of event: NSAppleEventDescriptor?) -> Tokens {
    Tokens(sender: token(event, senderKeyword), actual: token(event, actualKeyword))
  }

  private static func token(_ event: NSAppleEventDescriptor?, _ keyword: AEKeywordCode)
    -> AuditToken?
  {
    guard let data = event?.attributeDescriptor(forKeyword: keyword)?.data else { return nil }

    return AuditToken(data: data)
  }
}
