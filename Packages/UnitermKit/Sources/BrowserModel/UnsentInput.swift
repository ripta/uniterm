import Foundation

/// One report from the unsent-input script of one frame. The script runs in an isolated world and
/// sends nothing else. The frame is a random token the script made for its document, since WebKit
/// gives the native side no stable identity for a frame.
public struct UnsentInputReport: Equatable, Sendable {
  /// The exact length of a frame token, in lowercase hexadecimal.
  public static let tokenLength = 32

  public let frame: String
  public let unsent: Bool

  public init(frame: String, unsent: Bool) {
    self.frame = frame
    self.unsent = unsent
  }

  /// Reads a message body. Anything but a dictionary with exactly a frame token and a real
  /// boolean is nil. A number that happens to be 0 or 1 is not a boolean.
  public init?(body: Any) {
    guard let object = body as? [String: Any], object.count == 2,
      let frame = object["frame"] as? String, frame.utf8.count == Self.tokenLength,
      frame.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }),
      let flag = object["unsent"] as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID()
    else { return nil }

    self.init(frame: frame, unsent: flag.boolValue)
  }
}

/// Which frames of one tab hold edited input. A tab is marked while any frame is. A frame's clean
/// report removes only that frame's own mark, so one frame cannot clear another's.
///
/// The ledger keeps only the marked frames, and at most `maximumFrames` of them. A dirty frame
/// past that bound cannot be remembered, so the ledger remembers that it dropped one and keeps the
/// tab marked until the next load. The failure is a question the user can answer, never a draft
/// lost without one.
public struct UnsentInputLedger: Equatable, Sendable {
  public static let maximumFrames = 64

  private var marked: Set<String> = []
  private var dropped = false

  public init() {}

  public var isMarked: Bool { !marked.isEmpty || dropped }

  /// Applies a report. True when the tab's mark changed.
  @discardableResult
  public mutating func apply(_ report: UnsentInputReport) -> Bool {
    let before = isMarked

    if report.unsent {
      if marked.count < Self.maximumFrames || marked.contains(report.frame) {
        marked.insert(report.frame)
      } else {
        dropped = true
      }
    } else {
      marked.remove(report.frame)
    }

    return isMarked != before
  }

  /// Forgets every frame, as a load of the page or a stopped content process does. True when
  /// the tab was marked.
  @discardableResult
  public mutating func clear() -> Bool {
    let was = isMarked

    marked = []
    dropped = false

    return was
  }
}
