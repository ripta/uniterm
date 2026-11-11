import AppKit
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
@MainActor
public final class PendingRequestsWindowController: NSWindowController {
  private enum Row {
    case request(ScriptHost.PendingRequest)
    case grant(ScriptHost.ExplicitGrant)
    case launch(ExecLaunchAuthority.Request)
    case launchGrant(ExecLaunchAuthority.Grant)
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
  private var rows: [Row] = []

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

    scriptHost?.onPendingRequestsChanged = { [weak self] in self?.refresh() }
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
        "Programs outside uniterm\u{2019}s panes that asked to act for a pane, and drivers that "
        + "asked to run:")

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

    let buttons = NSStackView(views: [
      grantButton, allowOnceButton, allowInPaneButton, denyButton, NSView(), revokeButton,
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
  private func refresh() {
    rows =
      (scriptHost?.allPendingRequests().map(Row.request) ?? [])
      + launches.requests.map(Row.launch)
      + (scriptHost?.allGrants().map(Row.grant) ?? []) + launches.grants.map(Row.launchGrant)

    tableView.reloadData()
    updateButtons()
  }

  private var selectedRow: Row? {
    let index = tableView.selectedRow

    return rows.indices.contains(index) ? rows[index] : nil
  }

  private func updateButtons() {
    let row = selectedRow

    grantButton.isEnabled = false
    allowOnceButton.isEnabled = false
    allowInPaneButton.isEnabled = false
    denyButton.isEnabled = false
    revokeButton.isEnabled = false

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
    guard case .launch(let request) = selectedRow else { return }

    launches.decide(request.id, .allowOnce)
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
