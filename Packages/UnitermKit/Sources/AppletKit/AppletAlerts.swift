import Foundation
import StatusKit

/// What began a load. A notice about the load follows the origin it carries.
///
/// An applet sets the origin when it starts a load, and keeps it with that load's generation. A
/// later load sets its own. The origin is never a stored flag that outlives its load, since a
/// sort or filter the user makes on a restored pane is a user action.
public enum LoadOrigin: Sendable, Equatable {
  /// The first load of a pane that the host built from the saved layout of an earlier launch.
  case restore

  /// The user's own action: opening a file, a drop, choosing a sheet, or sorting.
  case user

  /// The same file read again, as when a file watcher sees a change or the user reverts.
  case reload
}

/// The alerts an applet shows, and the ones it holds back while it is detached.
///
/// An alert is a notice the user would notice but cannot see while the pane is off screen. Each
/// applet owns one of these and calls it from its own responses to `detach` and `reattach`. The
/// host never infers this policy or takes it over.
///
/// While attached, an alert is delivered by its origin. A restore-origin info goes to the history
/// only, a restore-origin warning raises the lesser unseen signal without a turn on the bar, and
/// everything else takes a turn on the bar. A notice that says its pane already explains it goes
/// to the history only, whatever its origin.
///
/// While detached, every alert is recorded in the history at once, with no signal and no turn. The
/// applet keeps the record's ID and the delivery the alert would have had. `reattach` presents the
/// held alerts through those records, so the history gets no second entry. A pane that closes
/// while detached keeps its records, since they were made when the events happened.
///
/// The held alerts are bounded in count and bytes. When the bound drops one, a count of what was
/// lost goes out on reattach as one more alert, at the most severe level lost.
@MainActor
public struct AppletAlerts {
  /// One held alert. Its bytes are its text plus a fixed 64 for the fields.
  struct Held {
    var level: StatusLevel
    var text: String
    var delivery: StatusDelivery
    var record: StatusRecordID?

    var bytes: Int { text.utf8.count + 64 }
  }

  /// The most alerts held while detached. A policy value with no setting.
  static let heldLimit = 8

  /// The most bytes held while detached. Each alert's text is cut to the status text bound, so
  /// the count limit binds first for ordinary text.
  static let heldBytes = 8 * 1024

  public private(set) var isDetached = false

  private(set) var held: [Held] = []

  /// The alerts the bound dropped while detached, and the most severe level and strongest delivery
  /// among them.
  private(set) var overflow = 0
  private var overflowLevel = StatusLevel.info
  private var overflowDelivery = StatusDelivery.attention

  public init() {}

  /// How many alerts wait for `reattach`.
  public var heldCount: Int { held.count }

  /// How many alerts the bound has dropped from the wait.
  public var overflowCount: Int { overflow }

  /// How a notice reaches the user while the pane is on screen.
  public static func delivery(of notice: AppletNotice, origin: LoadOrigin) -> StatusDelivery {
    guard notice.delivery == .message else { return .historyOnly }

    guard origin == .restore else { return .message }

    switch notice.level {
    case .info: return .historyOnly
    case .warning: return .attention
    case .error: return .message
    }
  }

  /// Delivers `notice`, or records and holds it while the applet is detached.
  public mutating func deliver(
    _ notice: AppletNotice, origin: LoadOrigin, from applet: any Applet,
    to host: (any AppletHost)?
  ) {
    let delivery = Self.delivery(of: notice, origin: origin)

    guard isDetached else {
      host?.applet(
        applet, send: delivery, level: notice.level, text: notice.text, presenting: nil)
      return
    }

    let record = host?.applet(
      applet, send: .historyOnly, level: notice.level, text: notice.text, presenting: nil)

    guard delivery != .historyOnly else { return }

    hold(
      Held(
        level: notice.level,
        text: StatusText.bounded(
          notice.text, maximumBytes: StatusPolicy.standard.maximumTextBytes),
        delivery: delivery, record: record))
  }

  /// Delivers an alert that has no load behind it, such as a terminal notification.
  public mutating func deliver(
    _ level: StatusLevel, _ text: String, from applet: any Applet, to host: (any AppletHost)?
  ) {
    deliver(AppletNotice(level, text), origin: .user, from: applet, to: host)
  }

  /// The applet left the screen. Alerts from here on are recorded and held.
  public mutating func detach() {
    isDetached = true
  }

  /// The applet is back. It presents what it held, oldest first, without adding the same history
  /// entries again. A count of the alerts the bound dropped goes first.
  public mutating func reattach(from applet: any Applet, to host: (any AppletHost)?) {
    guard isDetached else { return }

    isDetached = false

    let released = held
    let lost = overflow
    let lostLevel = overflowLevel
    let lostDelivery = overflowDelivery

    discard()

    guard let host else { return }

    if lost > 0 {
      let noun = lost == 1 ? "alert arrived" : "alerts arrived"

      host.applet(
        applet, send: lostDelivery, level: lostLevel,
        text: "\(lost.formatted()) more \(noun) while this pane was hidden. The history has them.",
        presenting: nil)
    }

    for alert in released {
      host.applet(
        applet, send: alert.delivery, level: alert.level, text: alert.text,
        presenting: alert.record)
    }
  }

  /// Lets go of whatever waits, as when the applet closes. The records stay in the history.
  public mutating func discard() {
    held = []
    overflow = 0
    overflowLevel = .info
    overflowDelivery = .attention
  }

  private mutating func hold(_ alert: Held) {
    held.append(alert)

    while held.count > Self.heldLimit || held.reduce(0, { $0 + $1.bytes }) > Self.heldBytes {
      let index = held.firstIndex { $0.level != .error } ?? 0
      let dropped = held.remove(at: index)

      overflow += 1
      overflowLevel = max(overflowLevel, dropped.level)

      if dropped.delivery == .message { overflowDelivery = .message }
    }
  }
}
