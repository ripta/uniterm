import AppKit
import ControllerPackage
import ControllerTrust
import ScriptHost

/// The Controllers & Permissions window. It lists the remembered approvals, each by its version or
/// key selector with the fingerprint and the approved scopes, and the controller runs that are
/// live now, each with how it was approved.
///
/// Revoke on a remembered approval removes it from the policy file, then ends the authority of
/// every live run it admitted, with their waiting work. Revoke on a run ends that run's authority
/// alone and keeps any remembered approval, as the pane badge's Revoke does. Neither undoes what
/// an approved program already did.
@MainActor
public final class ControllersWindowController: NSWindowController {
  enum Row: Equatable {
    case policy(ControllerPolicy)
    case run(ControllerRun)
  }

  private let scriptHost: ScriptHost
  private let tableView = NSTableView()
  private let detail = NSTextField(wrappingLabelWithString: "")
  private let notice = NSTextField(wrappingLabelWithString: "")
  private let revokeButton = NSButton(title: "Revoke", target: nil, action: nil)
  private var observer: ChangeObservers.Token?
  private var reading: Task<Void, Never>?

  private(set) var rows: [Row] = []

  public init(scriptHost: ScriptHost) {
    self.scriptHost = scriptHost

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 720, height: 420),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)

    window.title = "Controllers & Permissions"
    window.identifier = NSUserInterfaceItemIdentifier("controllers-window")
    window.setAccessibilityIdentifier("controllers-window")
    window.isReleasedWhenClosed = false
    window.isRestorable = false

    super.init(window: window)

    buildContent()
    observer = scriptHost.changes.add { [weak self] in self?.refresh() }
    refresh()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  public func present() {
    NSApp.activate()
    refresh()
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
  }

  private func buildContent() {
    guard let contentView = window?.contentView else { return }

    let heading = NSTextField(
      labelWithString: "Remembered controller approvals, and the controller runs live now:")

    heading.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)

    for (identifier, title, width) in [
      ("controller", "Controller", 260.0), ("selector", "Approved As", 200.0),
      ("scopes", "Powers", 220.0),
    ] {
      let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))

      column.title = title
      column.width = width
      tableView.addTableColumn(column)
    }

    tableView.dataSource = self
    tableView.delegate = self
    tableView.usesAlternatingRowBackgroundColors = true
    tableView.setAccessibilityIdentifier("controllers-table")

    let scrollView = NSScrollView()

    scrollView.documentView = tableView
    scrollView.hasVerticalScroller = true

    detail.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
    detail.isSelectable = true
    detail.setAccessibilityIdentifier("controllers-detail")
    notice.textColor = .secondaryLabelColor
    notice.setAccessibilityIdentifier("controllers-notice")

    revokeButton.target = self
    revokeButton.action = #selector(revokePressed)
    revokeButton.setAccessibilityIdentifier("controllers-revoke")

    for view in [heading, scrollView, detail, notice, revokeButton] {
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
      detail.bottomAnchor.constraint(equalTo: notice.topAnchor, constant: -8),
      detail.heightAnchor.constraint(greaterThanOrEqualToConstant: 80),

      notice.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
      notice.trailingAnchor.constraint(equalTo: revokeButton.leadingAnchor, constant: -12),
      notice.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),

      revokeButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
      revokeButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
    ])
  }

  /// Reads the policy file off the main actor, then lists it with the live runs. A read that a
  /// later one overtakes is dropped.
  func refresh() {
    reading?.cancel()
    reading = Task { @MainActor [weak self] in
      guard let self else { return }

      let state = await scriptHost.rememberedTrust()

      guard !Task.isCancelled else { return }

      show(policies: state.policies, notice: state.notice)
    }
  }

  /// Waits for the read in progress, so a test sees what the window shows.
  func settle() async {
    await reading?.value
  }

  /// The selection follows the row the user chose, a policy by its selector and a run by its
  /// connection, since rows come and go and a run's row changes as its powers do. When that row
  /// is gone, nothing is selected, so Revoke never acts on a row the user did not choose.
  private func show(policies: [ControllerPolicy], notice text: String?) {
    let selected = selectedRow.map(Self.identity)

    rows =
      policies.sorted {
        ($0.selector.controllerID, $0.approved) < ($1.selector.controllerID, $1.approved)
      }
      .map(Row.policy) + scriptHost.allControllerRuns().map(Row.run)
    notice.stringValue = text ?? ""
    tableView.reloadData()

    if let selected, let index = rows.firstIndex(where: { Self.identity($0) == selected }) {
      tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    } else {
      tableView.deselectAll(nil)
    }

    updateDetail()
  }

  private enum RowIdentity: Equatable {
    case policy(ControllerSelector)
    case run(UInt64)
  }

  private static func identity(_ row: Row) -> RowIdentity {
    switch row {
    case .policy(let policy): return .policy(policy.selector)
    case .run(let run): return .run(run.connection)
    }
  }

  private var selectedRow: Row? {
    let index = tableView.selectedRow

    return rows.indices.contains(index) ? rows[index] : nil
  }

  private func updateDetail() {
    revokeButton.isEnabled = selectedRow != nil
    detail.stringValue = selectedRow.map(Self.describe) ?? ""
  }

  static func selectorText(_ selector: ControllerSelector) -> String {
    switch selector {
    case .version(_, let version): return "Version \(version.prefix(16))\u{2026}"
    case .identity(_, let fingerprint): return "Key \(fingerprint.prefix(16))\u{2026}"
    }
  }

  static func describe(_ row: Row) -> String {
    switch row {
    case .policy(let policy):
      let selector: String

      switch policy.selector {
      case .version(let id, let version):
        selector = "Trusted version of \(id)\nVersion: \(version)"

      case .identity(let id, let fingerprint):
        selector =
          "Trusted identity: \(id), every version this key signs\nKey fingerprint: \(fingerprint)"
      }

      return
        ([selector, "Approved: \(policy.approved)", "Powers:"]
        + policy.scopes.sorted().map { "  \(LaunchApprovalText.escaped($0.displayText))" })
        .joined(separator: "\n")

    case .run(let run):
      let key = run.identity.keyFingerprint.map { "Key fingerprint: \($0)" } ?? "Unsigned"

      return
        ([
          "Live run of \(LaunchApprovalText.escaped(run.name)) (\(run.identity.controllerID)), "
            + "process \(run.pid)",
          "Version: \(run.identity.version)", key, run.approval.displayText, "Powers it asked for:",
        ]
        + run.scopes.sorted().map {
          "  \(LaunchApprovalText.escaped($0.displayText))"
            + (run.standing.contains($0) ? "" : ", asks each time")
        }).joined(separator: "\n")
    }
  }

  @objc private func revokePressed() {
    guard let row = selectedRow else { return }

    Task { @MainActor [weak self] in
      guard let self else { return }

      await revoke(row)
    }
  }

  /// Revokes what a row shows. A remembered approval also ends the runs it admitted.
  func revoke(_ row: Row) async {
    switch row {
    case .policy(let policy):
      if let failure = await scriptHost.forgetPolicy(policy.selector), let window {
        let alert = NSAlert()

        alert.alertStyle = .warning
        alert.messageText = "The approval was not removed"
        alert.informativeText = failure
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window) { _ in }
      }

    case .run(let run):
      scriptHost.revokeControllers([run.connection])
    }

    refresh()
    await settle()
  }
}

extension ControllersWindowController: NSTableViewDataSource, NSTableViewDelegate {
  public func numberOfRows(in tableView: NSTableView) -> Int {
    rows.count
  }

  public func tableView(
    _ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int
  ) -> Any? {
    guard rows.indices.contains(row) else { return nil }

    switch (rows[row], tableColumn?.identifier.rawValue) {
    case (.policy(let policy), "controller"):
      return "\(LaunchApprovalText.escaped(policy.name)) (\(policy.selector.controllerID))"
    case (.policy(let policy), "selector"): return Self.selectorText(policy.selector)
    case (.policy(let policy), "scopes"):
      return policy.scopes.sorted().map(\.kindName).joined(separator: ", ")
    case (.run(let run), "controller"):
      return "\(LaunchApprovalText.escaped(run.name)) (\(run.identity.controllerID))"
    case (.run(let run), "selector"): return "Live run, PID \(run.pid): \(run.approval.displayText)"
    case (.run(let run), "scopes"):
      return run.scopes.sorted().map(\.kindName).joined(separator: ", ")
    default: return nil
    }
  }

  public func tableViewSelectionDidChange(_ notification: Notification) {
    updateDetail()
  }
}
