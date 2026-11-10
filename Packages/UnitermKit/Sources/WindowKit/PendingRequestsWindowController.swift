import AppKit
import PaneModel
import ScriptHost

/// The panel that lists programs asking for a pane, and the grants the user has made.
///
/// A program outside every uniterm pane has no pane access. The user grants one connection one
/// pane here, denies it, or revokes a grant. Nothing here lasts past the connection.
@MainActor
public final class PendingRequestsWindowController: NSWindowController {
  private enum Row {
    case request(ScriptHost.PendingRequest)
    case grant(ScriptHost.ExplicitGrant)
  }

  private let scriptHost: ScriptHost
  private let windows: WindowSet
  private let tableView = NSTableView()
  private let grantButton = NSButton(title: "Grant Access\u{2026}", target: nil, action: nil)
  private let denyButton = NSButton(title: "Deny", target: nil, action: nil)
  private let revokeButton = NSButton(title: "Revoke", target: nil, action: nil)
  private var rows: [Row] = []

  public init(scriptHost: ScriptHost, windows: WindowSet) {
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

    scriptHost.onPendingRequestsChanged = { [weak self] in self?.refresh() }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func buildContent() {
    guard let contentView = window?.contentView else { return }

    let heading = NSTextField(
      labelWithString: "Programs outside uniterm's panes that asked to act for a pane:")

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

    grantButton.target = self
    grantButton.action = #selector(grantPressed)
    denyButton.target = self
    denyButton.action = #selector(denyPressed)
    revokeButton.target = self
    revokeButton.action = #selector(revokePressed)

    let buttons = NSStackView(views: [grantButton, denyButton, NSView(), revokeButton])

    buttons.orientation = .horizontal

    for view in [heading, scrollView, buttons] {
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
      scrollView.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -16),

      buttons.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
      buttons.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
      buttons.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
    ])
  }

  /// Reads the requests and grants again. The script host calls it whenever either changes.
  private func refresh() {
    rows =
      scriptHost.allPendingRequests().map(Row.request) + scriptHost.allGrants().map(Row.grant)

    tableView.reloadData()
    updateButtons()
  }

  private var selectedRow: Row? {
    let index = tableView.selectedRow

    return rows.indices.contains(index) ? rows[index] : nil
  }

  private func updateButtons() {
    switch selectedRow {
    case .request:
      grantButton.isEnabled = true
      denyButton.isEnabled = true
      revokeButton.isEnabled = false

    case .grant:
      grantButton.isEnabled = false
      denyButton.isEnabled = false
      revokeButton.isEnabled = true

    case nil:
      grantButton.isEnabled = false
      denyButton.isEnabled = false
      revokeButton.isEnabled = false
    }
  }

  @objc private func grantPressed() {
    guard case .request(let request) = selectedRow else { return }

    askForPane(for: request)
  }

  @objc private func denyPressed() {
    guard case .request(let request) = selectedRow else { return }

    scriptHost.denyRequest(connection: request.id)
  }

  @objc private func revokePressed() {
    guard case .grant(let grant) = selectedRow else { return }

    scriptHost.revokeGrant(connection: grant.connection)
  }

  /// The panes a grant can name: those that run a recorded session, in window order.
  private func grantablePanes() -> [(title: String, window: UInt64, pane: NodeID)] {
    windows.controllers.flatMap { controller in
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

      self.report(
        self.scriptHost.grantAccess(connection: request.id, window: pane.window, pane: pane.pane))
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
