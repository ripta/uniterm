import AppKit
import ControllerPackage
import ControllerTrust
import PaneModel
import ScriptHost

/// The panel that lists programs asking for a pane, exec drivers asking to run, and the grants
/// the user has made for either.
///
/// A program outside every uniterm pane has no pane access. The user grants one connection one
/// pane here, denies it, or revokes a grant. Nothing here lasts past the connection.
///
/// A driver launch shows every input it binds: its argv, its directory, its environment values,
/// and its pane. Allow Once runs exactly those inputs once. Allow in This Pane also lets later
/// runs of the same program, in the same directory and pane, with no environment key beyond
/// these, start without asking, whatever their arguments and values. These buttons are the only
/// way a launch is approved.
///
/// A controller's startup review lists the powers it asks for once, and Review opens the sheet
/// that answers it. A permission question from a script, a driver, or a terminal waits here as one
/// row however many times it is asked. A denial stays listed, and Ask Again is the only way to be
/// asked again.
@MainActor
public final class PendingRequestsWindowController: NSWindowController {
  private enum Row {
    case request(ScriptHost.PendingRequest)
    case grant(ScriptHost.ExplicitGrant)
    case launch(ExecLaunchAuthority.Request)
    case launchGrant(ExecLaunchAuthority.Grant)
    case review(ControllerReview)
    case question(PermissionRequests.Row)
    case denial(PermissionRequests.Denial)

    /// What the row is about, which stays the same while its contents change.
    var identity: RowIdentity {
      switch self {
      case .request(let request): return .request(request.id)
      case .grant(let grant): return .grant(grant.connection)
      case .launch(let request): return .launch(request.id)
      case .launchGrant(let grant): return .launchGrant(grant.id)
      case .review(let review): return .review(review.id)
      case .question(let question): return .question(question.id)
      case .denial(let denial): return .denial(denial.id)
      }
    }
  }

  private enum RowIdentity: Equatable {
    case request(UInt64)
    case grant(UInt64)
    case launch(UInt64)
    case launchGrant(UInt64)
    case review(UInt64)
    case question(UInt64)
    case denial(UInt64)
  }

  private let scriptHost: ScriptHost?
  private let windows: WindowSet
  private let tableView = NSTableView()
  private let detail = NSTextField(wrappingLabelWithString: "")
  private let grantButton = NSButton(title: "Grant Access\u{2026}", target: nil, action: nil)
  private let allowOnceButton = NSButton(title: "Allow Once", target: nil, action: nil)
  private let allowInPaneButton = NSButton(title: "Allow in This Pane", target: nil, action: nil)
  private let denyButton = NSButton(title: "Deny", target: nil, action: nil)
  private let revokeButton = NSButton(title: "Revoke", target: nil, action: nil)
  private let reviewButton = NSButton(title: "Review\u{2026}", target: nil, action: nil)
  private let sessionButton = NSButton(title: "Allow for This Run", target: nil, action: nil)
  private let askAgainButton = NSButton(title: "Ask Again", target: nil, action: nil)
  private var rows: [Row] = []
  private var observers: [ChangeObservers.Token] = []

  private var permissions: PermissionRequests { windows.permissionRequests }

  private var launches: ExecLaunchAuthority { windows.launchAuthority }

  public init(scriptHost: ScriptHost?, windows: WindowSet) {
    self.scriptHost = scriptHost
    self.windows = windows

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)

    window.title = "Pending Requests"
    window.identifier = NSUserInterfaceItemIdentifier("pending-requests-window")
    window.setAccessibilityIdentifier("pending-requests-window")
    window.isReleasedWhenClosed = false

    super.init(window: window)

    buildContent()
    refresh()

    if let scriptHost {
      observers.append(scriptHost.changes.add { [weak self] in self?.refresh() })
    }

    observers.append(windows.permissionRequests.changes.add { [weak self] in self?.refresh() })
    windows.launchAuthority.onChange = { [weak self] in self?.refresh() }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func buildContent() {
    guard let contentView = window?.contentView else { return }

    let heading = NSTextField(
      labelWithString:
        "Programs that asked to act for a pane, controllers and drivers that asked to run, and "
        + "permissions programs asked for:")

    heading.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)

    for (identifier, title, width) in [
      ("program", "Program", 300.0), ("pid", "PID", 70.0), ("status", "Status", 200.0),
    ] {
      let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))

      column.title = title
      column.width = width
      tableView.addTableColumn(column)
    }

    tableView.dataSource = self
    tableView.delegate = self
    tableView.usesAlternatingRowBackgroundColors = true
    tableView.setAccessibilityIdentifier("pending-requests-table")

    let scrollView = NSScrollView()

    scrollView.documentView = tableView
    scrollView.hasVerticalScroller = true

    detail.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
    detail.isSelectable = true
    detail.setAccessibilityIdentifier("pending-requests-detail")

    grantButton.target = self
    grantButton.action = #selector(grantPressed)
    allowOnceButton.target = self
    allowOnceButton.action = #selector(allowOncePressed)
    allowOnceButton.setAccessibilityIdentifier("pending-requests-allow-once")
    allowInPaneButton.target = self
    allowInPaneButton.action = #selector(allowInPanePressed)
    allowInPaneButton.setAccessibilityIdentifier("pending-requests-allow-in-pane")
    denyButton.target = self
    denyButton.action = #selector(denyPressed)
    revokeButton.target = self
    revokeButton.action = #selector(revokePressed)
    reviewButton.target = self
    reviewButton.action = #selector(reviewPressed)
    reviewButton.setAccessibilityIdentifier("pending-requests-review")
    sessionButton.target = self
    sessionButton.action = #selector(sessionPressed)
    sessionButton.setAccessibilityIdentifier("pending-requests-allow-session")
    askAgainButton.target = self
    askAgainButton.action = #selector(askAgainPressed)
    askAgainButton.setAccessibilityIdentifier("pending-requests-ask-again")

    let buttons = NSStackView(views: [
      grantButton, reviewButton, allowOnceButton, allowInPaneButton, sessionButton, denyButton,
      NSView(), askAgainButton, revokeButton,
    ])

    buttons.orientation = .horizontal

    for view in [heading, scrollView, detail, buttons] {
      view.translatesAutoresizingMaskIntoConstraints = false
      contentView.addSubview(view)
    }

    NSLayoutConstraint.activate([
      heading.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
      heading.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
      heading.trailingAnchor.constraint(
        lessThanOrEqualTo: contentView.trailingAnchor, constant: -20),

      scrollView.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 12),
      scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
      scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
      scrollView.bottomAnchor.constraint(equalTo: detail.topAnchor, constant: -12),

      detail.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
      detail.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
      detail.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -12),
      detail.heightAnchor.constraint(greaterThanOrEqualToConstant: 64),

      buttons.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
      buttons.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
      buttons.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
    ])
  }

  /// Reads the requests and grants again. The script host and the launch authority call it
  /// whenever either changes.
  ///
  /// The selection follows the row the user chose, not its position, since rows above it come
  /// and go. When that row is gone, nothing is selected, so no button acts on a row the user did
  /// not choose.
  private func refresh() {
    let chosen = selectedRow?.identity

    rows =
      (scriptHost?.controllerReviews.map(Row.review) ?? [])
      + (scriptHost?.allPendingRequests().map(Row.request) ?? [])
      + launches.requests.map(Row.launch) + permissions.rows.map(Row.question)
      + (scriptHost?.allGrants().map(Row.grant) ?? []) + launches.grants.map(Row.launchGrant)
      + permissions.denials.map(Row.denial)

    tableView.reloadData()

    if let chosen, let index = rows.firstIndex(where: { $0.identity == chosen }) {
      tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    } else {
      tableView.deselectAll(nil)
    }

    updateButtons()
  }

  private var selectedRow: Row? {
    let index = tableView.selectedRow

    return rows.indices.contains(index) ? rows[index] : nil
  }

  private func updateButtons() {
    let row = selectedRow

    for button in [
      grantButton, allowOnceButton, allowInPaneButton, denyButton, revokeButton, reviewButton,
      sessionButton, askAgainButton,
    ] {
      button.isEnabled = false
    }

    sessionButton.isHidden = true
    allowInPaneButton.isHidden = false

    switch row {
    case .request:
      grantButton.isEnabled = true
      denyButton.isEnabled = true

    case .launch:
      allowOnceButton.isEnabled = true
      allowInPaneButton.isEnabled = true
      denyButton.isEnabled = true

    case .grant, .launchGrant:
      revokeButton.isEnabled = true

    case .review:
      reviewButton.isEnabled = true
      allowOnceButton.isEnabled = true
      allowInPaneButton.isHidden = true
      sessionButton.isHidden = false
      sessionButton.isEnabled = true
      sessionButton.title = "Allow for This Session"
      denyButton.isEnabled = true

    case .question(let question):
      allowOnceButton.isEnabled = true
      allowInPaneButton.isHidden = true
      sessionButton.isHidden = false
      sessionButton.isEnabled = true
      sessionButton.title = question.sessionTitle
      denyButton.isEnabled = true

    case .denial:
      askAgainButton.isEnabled = true

    case nil:
      break
    }

    detail.stringValue = row.map(describe) ?? ""
  }

  /// Every input a launch binds, or the scope a grant covers, in full.
  private func describe(_ row: Row) -> String {
    switch row {
    case .launch(let request):
      return LaunchApprovalText.request(
        request.launch, pane: paneTitle(request.target, fallback: request.paneTitle))

    case .launchGrant(let grant):
      return LaunchApprovalText.grant(
        grant, pane: paneTitle(grant.target, fallback: grant.paneTitle))

    case .review(let review):
      return ControllerReviewText.summary(review)

    case .question(let question):
      return question.waiting > 1
        ? "\(question.detail)\n\(question.waiting) requests wait. Allow Once allows the oldest alone."
        : question.detail

    case .denial(let denial):
      return
        "You denied \(denial.subject): \(denial.title). Later requests are refused without "
        + "asking until you choose Ask Again."

    case .request, .grant:
      return ""
    }
  }

  private func paneTitle(_ target: ExecLaunchAuthority.Target, fallback: String) -> String {
    guard let controller = windows.controller(forScriptWindow: target.window),
      let applet = controller.paneArea.applet(for: target.pane)
    else { return fallback }

    return "\(controller.window?.title ?? "Window"): \(applet.title)"
  }

  @objc private func allowOncePressed() {
    switch selectedRow {
    case .launch(let request): launches.decide(request.id, .allowOnce)
    case .question(let question): permissions.decide(question.id, .allowOnce)
    case .review(let review): answer(review, .allowOnce)
    default: break
    }
  }

  @objc private func sessionPressed() {
    switch selectedRow {
    case .question(let question): permissions.decide(question.id, .allowForSession)
    case .review(let review): answer(review, .allowForSession)
    default: break
    }
  }

  @objc private func askAgainPressed() {
    guard case .denial(let denial) = selectedRow else { return }

    permissions.askAgain(denial.id)
  }

  /// The sheet offers every choice with its explanation. The panel answers the choices that need
  /// no more than the summary it already shows, so the trust choices stay in the sheet.
  @objc private func reviewPressed() {
    guard case .review(let review) = selectedRow else { return }

    Task { @MainActor [weak self] in
      guard let choice = await ControllerReviewSheet.present(review, on: self?.window) else {
        return
      }

      self?.answer(review, choice)
    }
  }

  private func answer(_ review: ControllerReview, _ choice: ControllerReviewChoice) {
    Task { @MainActor [weak self] in
      guard let self, let scriptHost,
        let failure = await scriptHost.decideReview(review.id, choice), let window
      else { return }

      let alert = NSAlert()

      alert.alertStyle = .warning
      alert.messageText = "The review was not answered"
      alert.informativeText = failure
      alert.addButton(withTitle: "OK")
      alert.beginSheetModal(for: window) { _ in }
    }
  }

  @objc private func allowInPanePressed() {
    guard case .launch(let request) = selectedRow else { return }

    launches.decide(request.id, .allowInPane)
  }

  @objc private func grantPressed() {
    guard case .request(let request) = selectedRow else { return }

    askForPane(for: request)
  }

  @objc private func denyPressed() {
    switch selectedRow {
    case .request(let request): scriptHost?.denyRequest(connection: request.id)
    case .launch(let request): launches.decide(request.id, .deny)
    case .question(let question): permissions.decide(question.id, .deny)
    case .review(let review): answer(review, .deny)
    default: break
    }
  }

  @objc private func revokePressed() {
    switch selectedRow {
    case .grant(let grant): scriptHost?.revokeGrant(connection: grant.connection)
    case .launchGrant(let grant): launches.revokeGrant(grant.id)
    default: break
    }
  }

  /// The panes a grant can name: those that run a recorded session, in window order.
  private func grantablePanes() -> [(title: String, window: UInt64, pane: NodeID)] {
    guard let scriptHost else { return [] }

    return windows.controllers.flatMap { controller in
      controller.paneIDs.compactMap { pane in
        guard let applet = controller.paneArea.applet(for: pane),
          scriptHost.sessionRoot(window: controller.scriptWindowID, pane: pane) != nil
        else { return nil }

        let windowTitle = controller.window?.title ?? "Window"

        return ("\(windowTitle): \(applet.title)", controller.scriptWindowID, pane)
      }
    }
  }

  private func askForPane(for request: ScriptHost.PendingRequest) {
    guard let window else { return }

    let program = request.executablePath ?? request.name
    let panes = grantablePanes()
    let alert = NSAlert()

    guard !panes.isEmpty else {
      alert.messageText = "No pane can be granted"
      alert.informativeText = "Only a terminal or REPL pane with a running session can be granted."
      alert.addButton(withTitle: "OK")
      alert.beginSheetModal(for: window)

      return
    }

    let popup = NSPopUpButton()

    popup.setAccessibilityIdentifier("pending-requests-pane")

    for (index, pane) in panes.enumerated() {
      popup.addItem(withTitle: pane.title)
      popup.lastItem?.tag = index
    }

    popup.sizeToFit()

    alert.messageText = "Let this program act for a pane?"
    alert.informativeText =
      "\(program), process \(request.pid), may then act for the pane you choose, in that pane's "
      + "window only. The grant ends when the program disconnects or exits, when the pane's "
      + "session ends, when the window closes, or when you revoke it."
    alert.accessoryView = popup
    alert.addButton(withTitle: "Grant")
    alert.addButton(withTitle: "Cancel")

    alert.beginSheetModal(for: window) { [weak self] response in
      guard response == .alertFirstButtonReturn, let self,
        panes.indices.contains(popup.selectedTag())
      else { return }

      let pane = panes[popup.selectedTag()]

      guard let scriptHost = self.scriptHost else { return }

      self.report(
        scriptHost.grantAccess(connection: request.id, window: pane.window, pane: pane.pane))
    }
  }

  private func report(_ result: ScriptHost.GrantResult) {
    guard let window else { return }

    let alert = NSAlert()

    switch result {
    case .granted:
      return

    case .connectionClosed:
      alert.messageText = "The program has gone"
      alert.informativeText = "It disconnected or exited before the grant, so nothing was granted."

    case .failed(let reason):
      alert.messageText = "Nothing was granted"
      alert.informativeText = reason
    }

    alert.alertStyle = .warning
    alert.addButton(withTitle: "OK")
    alert.beginSheetModal(for: window)
  }
}

extension PendingRequestsWindowController: NSTableViewDataSource, NSTableViewDelegate {
  public func numberOfRows(in tableView: NSTableView) -> Int {
    rows.count
  }

  public func tableView(
    _ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int
  ) -> Any? {
    guard rows.indices.contains(row) else { return nil }

    switch (rows[row], tableColumn?.identifier.rawValue) {
    case (.request(let request), "program"): return request.executablePath ?? request.name
    case (.request(let request), "pid"): return String(request.pid)
    case (.request, "status"): return "Waiting"
    case (.grant(let grant), "program"): return grant.executablePath ?? "unknown"
    case (.grant(let grant), "pid"): return String(grant.pid)
    case (.grant(let grant), "status"): return "Granted \(paneTitle(grant))"
    case (.launch(let request), "program"): return request.launch.declaration.executable
    case (.launch, "pid"): return "\u{2014}"
    case (.launch(let request), "status"):
      return "Wants to run in \(paneTitle(request.target, fallback: request.paneTitle))"
    case (.launchGrant(let grant), "program"): return grant.executable
    case (.launchGrant, "pid"): return "\u{2014}"
    case (.launchGrant(let grant), "status"):
      return "Allowed in \(paneTitle(grant.target, fallback: grant.paneTitle))"
    case (.review(let review), "program"): return "\(review.name) (\(review.identity.controllerID))"
    case (.review(let review), "pid"):
      return review.waiting.map { String($0.pid) }.joined(separator: ", ")
    case (.review(let review), "status"):
      return review.waiting.count > 1
        ? "Waits for review, \(review.waiting.count) runs" : "Waits for review"
    case (.question(let question), "program"): return question.subject
    case (.question, "pid"): return "\u{2014}"
    case (.question(let question), "status"):
      return question.waiting > 1
        ? "\(question.title), \(question.waiting) waiting" : question.title
    case (.denial(let denial), "program"): return denial.subject
    case (.denial, "pid"): return "\u{2014}"
    case (.denial(let denial), "status"): return "Denied: \(denial.title)"
    default: return nil
    }
  }

  public func tableViewSelectionDidChange(_ notification: Notification) {
    updateButtons()
  }

  private func paneTitle(_ grant: ScriptHost.ExplicitGrant) -> String {
    guard let controller = windows.controller(forScriptWindow: grant.window),
      let applet = controller.paneArea.applet(for: grant.pane)
    else { return "a closed pane" }

    return "\(controller.window?.title ?? "Window"): \(applet.title)"
  }
}
