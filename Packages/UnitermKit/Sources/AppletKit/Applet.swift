import AppKit
import StatusKit
import Theme

/// One slot an applet fills in the status bar, such as a mode or a line and column.
public struct AppletSegment: Sendable, Equatable {
  public enum Style: Sendable, Equatable {
    case normal
    case emphasized
    case warning
    case error
  }

  public var symbolName: String?
  public var text: String?
  public var style: Style

  public init(symbolName: String? = nil, text: String? = nil, style: Style = .normal) {
    self.symbolName = symbolName
    self.text = text
    self.style = style
  }
}

/// A question an applet asks the user. The host shows it, names the pane, and returns the answer.
public struct AppletConfirmation: Sendable, Equatable {
  public var title: String
  public var detail: String
  public var confirmTitle: String
  public var cancelTitle: String

  public init(title: String, detail: String, confirmTitle: String, cancelTitle: String) {
    self.title = title
    self.detail = detail
    self.confirmTitle = confirmTitle
    self.cancelTitle = cancelTitle
  }
}

/// The pane side of the applet contract. The host knows which pane an applet runs in, so it fills in
/// the message source.
@MainActor
public protocol AppletHost: AnyObject {
  /// Delivers `text` the way `delivery` says. With no `record`, the host admits a new history
  /// record. With the ID of a record the applet got from an earlier call, it presents that record
  /// again and adds none. Returns the record's ID. The protocol has no default for it, so a host
  /// cannot drop a delivery unnoticed.
  @discardableResult
  func applet(
    _ applet: any Applet, send delivery: StatusDelivery, level: StatusLevel, text: String,
    presenting record: StatusRecordID?
  ) -> StatusRecordID?

  /// The applet has nothing left to run, so its pane should close.
  func appletDidExit(_ applet: any Applet)

  /// The title or the segments changed.
  func appletDidChange(_ applet: any Applet)

  /// The applet's tab list changed: a tab opened, closed, or was selected, or a tab's title or
  /// details changed. It fires for tabs in the background too, which `appletDidChange` does not
  /// report.
  func appletTabsDidChange(_ applet: any Applet)

  /// Asks the user. Nothing happens until the user answers.
  func applet(_ applet: any Applet, confirm request: AppletConfirmation) async -> Bool

  /// The next close stamp of the window. Stamps only grow, and pane closes draw from the same
  /// counter, so the window can order a closed tab against a closed pane. An applet asks for one
  /// when it records a close, after any question has been answered.
  func issueCloseStamp() -> UInt64
}

extension AppletHost {
  /// A turn on the status bar, an entry in the history, and the unseen signal of the level.
  public func applet(_ applet: any Applet, post level: StatusLevel, text: String) {
    self.applet(applet, send: .message, level: level, text: text, presenting: nil)
  }

  /// Records `text` in the window's history without a turn on the bar and without an unseen
  /// signal. An applet whose pane already says the same thing records this way, and so does one
  /// that cannot be seen. Returns the record's ID.
  @discardableResult
  public func applet(
    _ applet: any Applet, recordInHistory level: StatusLevel, text: String
  ) -> StatusRecordID? {
    self.applet(applet, send: .historyOnly, level: level, text: text, presenting: nil)
  }
}

/// What built an applet that is about to start.
public enum StartOrigin: Sendable, Equatable {
  /// The window rebuilt the applet from the saved layout of an earlier launch.
  case restore

  /// Anything else: a new pane, a pane reopened by undo, or a launcher swap.
  case user

  /// The origin of the first load the applet begins.
  public var loadOrigin: LoadOrigin {
    switch self {
    case .restore: return .restore
    case .user: return .user
    }
  }
}

/// How an applet answers a request to reopen one of its closed tabs.
public enum TabReopenResult: Sendable, Equatable {
  /// The tab is back. The title names it for the window's message.
  case reopened(title: String)

  /// The applet holds no closed tab with this stamp.
  case missing

  /// The tab could not come back, and the applet is unchanged. The entry stays for another try.
  case failed(title: String, reason: String)
}

/// How an applet answers a request to close its current tab.
public enum TabCloseResult: Sendable, Equatable {
  /// The tab closed.
  case closed

  /// The user was asked and said no, or a close of the same tab is already waiting for an answer.
  case declined

  /// The applet has no tab to close. Closing the last tab is a pane close, which the host owns.
  case nothingToClose
}

/// What a pane runs. Every applet implements this contract.
///
/// The host sends the lifecycle events: `start`, `detach`, `reattach`, and `close`. It sends each
/// when it happens and does nothing else on the applet's behalf. It never keeps an applet alive
/// after closing it, and it never stops or signals the applet's work itself. Each applet decides
/// what an event means for its own content.
///
/// Undo reopens a closed pane from its description, in the same place, with the same kind of
/// applet. An applet that wants an undo to bring back more saves it in the description's undo-only
/// part, which a layout file never holds.
@MainActor
public protocol Applet: AnyObject {
  var typeID: String { get }

  /// The view the pane hosts. It stays the same for the applet's life.
  var view: NSView { get }

  var title: String { get }
  var segments: [AppletSegment] { get }

  /// The tabs the palette finds. It is never empty. An applet with nothing to switch between
  /// publishes one tab for its whole session. The applet tells the host when it changes, with
  /// `appletTabsDidChange`.
  var publishedTabs: AppletTabList { get }

  /// True when closing the applet would kill work that undo cannot bring back.
  var isRunningSomething: Bool { get }

  /// What a confirmation dialog calls the parts of the applet that are running something. An
  /// applet with tabs names each such tab, by title or by command. An applet that is not running
  /// anything names nothing.
  var runningLabels: [String] { get }

  /// Work a close would lose that saving keeps, such as pin edits not yet written to their file.
  /// Nil when there is none. Closing the pane, its window, or the app asks Save, Don't Save, or
  /// Cancel first.
  var unsavedWork: AppletUnsavedWork? { get }

  /// Saves the unsaved work. It may ask the user where, so it can take a while. True when the work
  /// is saved. False when the user cancelled or the save failed, which the applet reports itself,
  /// and the close does not go ahead.
  func saveUnsavedWork() async -> Bool

  var host: (any AppletHost)? { get set }

  /// The directory the applet's current work is in, as an absolute local path. A new pane opened
  /// from this one starts there. An applet with no such concept, or with no usable directory right
  /// now, returns nil and says nothing.
  var currentDirectory: String? { get }

  /// The applet is in a pane and on screen. It begins its work.
  ///
  /// The origin says what built the applet. `restore` means the window rebuilt it from the saved
  /// layout of an earlier launch, so the loads it begins are a restore and its notices say so. A
  /// pane reopened by undo, a launcher swap, and a new pane pass `user`. The origin has no default.
  /// An applet with no loads ignores it.
  func start(origin: StartOrigin)

  /// The host is done with the applet, and it is unusable afterwards. What the applet does next is
  /// its own choice. It may end its work at once, finish it after a delay, or save more state into
  /// its description. Work it keeps alive after close must be bounded in time and visible to the
  /// user.
  func close()

  /// The applet has left the screen and stays alive. It stops at once what the user would notice
  /// but cannot see. It pauses audio and video, and it holds back alerts. An applet with nothing
  /// perceptible to pause does nothing.
  ///
  /// Holding back an alert means withholding its presentation. The applet still records the alert
  /// in the history when it happens, and shows it again on `reattach`. `AppletAlerts` does both.
  func detach()

  /// The applet is back on screen. It undoes what `detach` did.
  func reattach()

  /// Selects the tab with this ID. Returns false when the applet has no such tab, as when it
  /// closed. An applet with one tab selects nothing and returns true when the ID is that tab's.
  func selectTab(id: AppletTabID) -> Bool

  /// Gives the applet keyboard focus.
  func focus()

  /// Closes the applet's current tab, after asking when it is running something. The answer says
  /// whether it closed, the user declined, or the applet has no tab to close. Only the last lets
  /// the host close the pane. An applet without tabs always answers that it has none.
  func closeCurrentTab() async -> TabCloseResult

  /// The stamps of the closed tabs the applet can reopen, newest first. The applet keeps the list.
  /// The host keeps no copy. An applet without tabs reports none.
  var closedTabStamps: [UInt64] { get }

  /// Reopens the closed tab with this stamp, in its former place. A failure keeps the entry, adds
  /// no tab, and leaves the selection as it was.
  func reopenTab(stamp: UInt64) -> TabReopenResult

  func describe() -> AppletDescription

  /// Tells the applet the palette to draw its own chrome with. The host calls it when the applet
  /// is installed and whenever the palette changes.
  func apply(_ palette: ThemePalette)
}

extension Applet {
  public func closeCurrentTab() async -> TabCloseResult { .nothingToClose }

  public var closedTabStamps: [UInt64] { [] }

  public func reopenTab(stamp: UInt64) -> TabReopenResult { .missing }

  public func apply(_ palette: ThemePalette) {}

  public func selectTab(id: AppletTabID) -> Bool {
    publishedTabs.contains(id)
  }

  public var currentDirectory: String? { nil }

  public var unsavedWork: AppletUnsavedWork? { nil }

  public func saveUnsavedWork() async -> Bool { true }

  /// An applet with one part running names itself by its title.
  public var runningLabels: [String] {
    isRunningSomething ? [title] : []
  }
}

/// Unsaved work an applet holds, as a close dialog names it.
public struct AppletUnsavedWork: Sendable, Equatable {
  /// What the dialog lists, such as the file's name. It is shown as is, so it carries no
  /// program-supplied text.
  public let label: String

  public init(label: String) {
    self.label = label
  }
}
