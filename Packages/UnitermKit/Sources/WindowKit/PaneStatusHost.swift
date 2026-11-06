import AppKit
import AppletKit
import PaneModel
import StatusKit

/// The host an applet holds. It is bound to one pane when the applet takes the pane, and it posts
/// for that pane only.
///
/// The pane ID is a stable identity. It does not depend on the pane still being in the tree, so a
/// message from an applet that outlives its pane keeps the ID it had. The `applet` argument of each
/// call is ignored for identity, so an applet cannot post as another pane.
///
/// The window owns the host's lifetime. It holds each one weakly bound to its applet and drops the
/// entries of applets that are gone.
@MainActor
final class PaneStatusHost: AppletHost {
  let pane: NodeID
  private weak var window: MainWindowController?
  private weak var bound: (any Applet)?
  private var lastTitle: String

  /// A record this host admitted, and whether it has been shown. An applet presents a record by
  /// ID. The host honors only its own records, once each. An ID it did not issue, or one that
  /// left the history, is delivered as a new record of this pane instead, so no pane can mark or
  /// show another's.
  ///
  /// The ledger keeps an entry exactly while the history keeps its record. Retention has one rule,
  /// so a record the pane still holds cannot fall off the ledger and come back as a duplicate.
  private struct Issued {
    var id: StatusRecordID
    var presented: Bool
  }

  private var ledger: [Issued] = []

  init(pane: NodeID, applet: any Applet, window: MainWindowController) {
    self.pane = pane
    self.window = window
    bound = applet
    lastTitle = applet.title
  }

  private var source: StatusSource {
    if let bound { lastTitle = bound.title }

    return .pane(id: pane.rawValue, name: lastTitle)
  }

  func applet(
    _ applet: any Applet, send delivery: StatusDelivery, level: StatusLevel, text: String,
    presenting record: StatusRecordID?
  ) -> StatusRecordID? {
    guard let window else { return nil }

    var target: StatusRecordID?

    if let record, let index = ledger.firstIndex(where: { $0.id == record }) {
      guard !ledger[index].presented else { return record }

      ledger[index].presented = true
      target = record
    }

    let id = window.statusCenter.deliver(
      delivery, level: level, source: source, text: text, presenting: target)

    if target == nil, let id {
      ledger.append(Issued(id: id, presented: delivery != .historyOnly))

      let retained = Set(window.statusCenter.history.map(\.id))

      ledger.removeAll { !retained.contains($0.id) }
    }

    return id
  }

  func appletDidExit(_ applet: any Applet) {
    window?.appletDidExit(applet)
  }

  func appletDidChange(_ applet: any Applet) {
    window?.appletDidChange(applet)
  }

  func appletTabsDidChange(_ applet: any Applet) {
    window?.appletTabsDidChange(applet)
  }

  func applet(_ applet: any Applet, confirm request: AppletConfirmation) async -> Bool {
    guard let window else { return false }

    return await window.applet(applet, confirm: request)
  }

  func issueCloseStamp() -> UInt64 {
    window?.issueCloseStamp() ?? 0
  }
}
