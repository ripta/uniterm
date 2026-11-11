import AppKit
import AppletKit
import ExecDriver
import PaneModel
import StatusKit

/// Asks the user for the values of a driver's environment keys before a run. Nil means the user
/// cancelled. The values live in memory for the pane's life and are never saved.
typealias ExecValuesAsker =
  @MainActor (_ keys: [String], _ program: String, _ window: NSWindow?) async -> [String: String]?

/// One pane's exec driver: what it declares, the values the user gave it, and where it stands.
///
/// The declaration is inert. Nothing runs until the user chooses Run in the pane, and a launch
/// then needs execution authority from the Pending Requests panel or a grant made there.
@MainActor
final class ExecAttachment {
  enum State {
    /// Not running. The note says why, and Run starts it.
    case idle(String)

    case waitingForValues
    case waitingForApproval

    case running(ExecDriverChannel)

    /// The driver stopped. The reason is shown, and Restart starts it again. Nothing restarts it
    /// by itself.
    case ended(String)
  }

  let declaration: ExecDeclaration
  var values: [String: String] = [:]
  var state: State

  /// Counts runs, so the end of an earlier run never changes a later one.
  var run: UInt64 = 0

  init(declaration: ExecDeclaration, note: String) {
    self.declaration = declaration
    state = .idle(note)
  }

  var program: String { (declaration.executable as NSString).lastPathComponent }

  var isBusy: Bool {
    switch state {
    case .idle, .ended: return false
    case .waitingForValues, .waitingForApproval, .running: return true
    }
  }

  var channel: ExecDriverChannel? {
    if case .running(let channel) = state { return channel }

    return nil
  }
}

// MARK: Exec drivers

extension MainWindowController {
  /// Gives the pane an exec driver declaration. It runs nothing. The pane's applet must take
  /// commands and its type must support an exec driver. A declaration already there is replaced,
  /// and a driver it was running is stopped.
  func declareExecDriver(_ declaration: ExecDeclaration, for pane: NodeID, restored: Bool = false)
    throws
  {
    guard let applet = paneArea.applet(for: pane), contains(pane: pane) else {
      throw ExecPaneError.notOpen
    }

    guard applet is any AppletCommandHandling,
      supportedControl(of: pane).contains(where: { $0.driver == .exec })
    else { throw ExecPaneError.unsupported(applet.typeID) }

    execAttachments[pane]?.channel?.close()

    let note =
      restored
      ? "Restored. Nothing runs until you choose Run."
      : "Not running. Choose Run to start it."

    execAttachments[pane] = ExecAttachment(declaration: declaration, note: note)
    refreshExecStatus(of: pane)
    onLayoutChange?()
  }

  /// The user's Run or Restart. It is a local action only: no script call and no driver command
  /// reaches it. A driver that needs environment values asks for them first, then the launch
  /// needs execution authority.
  func runExecDriver(_ pane: NodeID) {
    guard let attachment = execAttachments[pane], !attachment.isBusy else { return }

    let combination = ControlCombination(access: control(of: pane).access, driver: .exec)

    guard supportedControl(of: pane).contains(combination) else {
      attachment.state = .idle(
        "This pane does not support an exec driver while it is \(combination.access.rawValue).")
      refreshExecStatus(of: pane)
      return
    }

    let missing = attachment.declaration.environmentKeys.filter { attachment.values[$0] == nil }

    guard missing.isEmpty else {
      attachment.state = .waitingForValues
      refreshExecStatus(of: pane)

      Task { @MainActor [weak self, weak attachment] in
        guard let self, let attachment else { return }

        let values = await execValuesAsker(
          attachment.declaration.environmentKeys, attachment.program, window)

        guard execAttachments[pane] === attachment, case .waitingForValues = attachment.state
        else { return }

        guard let values else {
          attachment.state = .idle("Not running. Choose Run to start it.")
          refreshExecStatus(of: pane)
          return
        }

        attachment.values = values
        attachment.state = .idle("Not running.")
        runExecDriver(pane)
      }

      return
    }

    let launch: ExecLaunch

    do {
      launch = try ExecLaunch(
        declaration: attachment.declaration, environment: attachment.values,
        home: execEnvironment?.home ?? NSHomeDirectory())
    } catch {
      attachment.state = .ended("The driver cannot run: \(error).")
      refreshExecStatus(of: pane)
      return
    }

    let target = ExecLaunchAuthority.Target(window: scriptWindowID, pane: pane)

    if launchAuthority.grant(covering: launch, in: target) != nil {
      start(launch, for: attachment, in: pane)
      return
    }

    attachment.state = .waitingForApproval
    refreshExecStatus(of: pane)

    let requested = launchAuthority.request(
      launch, in: target, paneTitle: paneArea.applet(for: pane)?.title ?? "Pane"
    ) { [weak self, weak attachment] decision in
      guard let self, let attachment, execAttachments[pane] === attachment,
        case .waitingForApproval = attachment.state
      else { return }

      switch decision {
      case .allowOnce, .allowInPane:
        start(launch, for: attachment, in: pane)

      case .deny:
        attachment.state = .idle("Not allowed. Choose Run to ask again.")
        refreshExecStatus(of: pane)
      }
    }

    if requested == nil {
      attachment.state = .idle("Too many launches wait for approval. Answer some, then try again.")
      refreshExecStatus(of: pane)
    }
  }

  /// Starts exactly the launch that was approved. The applet learns of the driver before the
  /// driver can reach it, so its clipboard policy tightens first.
  private func start(_ launch: ExecLaunch, for attachment: ExecAttachment, in pane: NodeID) {
    guard let applet = paneArea.applet(for: pane) as? any AppletCommandHandling,
      let environment = execEnvironment
    else {
      attachment.state = .ended("The driver cannot run in this pane.")
      refreshExecStatus(of: pane)
      return
    }

    attachment.run += 1

    let run = attachment.run

    pushControl(paneControls.set(driver: .exec, for: pane), to: pane)

    let channel = ExecDriverChannel(
      launch: launch, environment: environment, applet: applet, dispatcher: dispatcher,
      authority: { [weak self, weak attachment] in
        guard let self, let attachment, execAttachments[pane] === attachment,
          attachment.run == run, contains(pane: pane)
        else { return AppletCommandError(.refused, "the driver no longer drives this pane") }

        return nil
      },
      producer: statusCenter.issueProducer(kind: .applet, name: "\(attachment.program) (driver)"),
      killGrace: execKillGrace,
      onEnd: { [weak self, weak attachment] end in
        guard let self, let attachment else { return }

        driverEnded(end, attachment: attachment, run: run, pane: pane)
      })

    attachment.state = .running(channel)

    do {
      try channel.start()
    } catch {
      attachment.state = .ended("The driver did not start: \(error).")
      pushControl(paneControls.set(driver: .none, for: pane), to: pane)
      statusCenter.post(level: .warning, text: "The driver did not start: \(error).")
    }

    refreshExecStatus(of: pane)
    refreshControlMarks()
  }

  private func driverEnded(
    _ end: ExecDriverChannel.End, attachment: ExecAttachment, run: UInt64, pane: NodeID
  ) {
    guard execAttachments[pane] === attachment, attachment.run == run, contains(pane: pane) else {
      return
    }

    attachment.state = .ended(end.description)
    pushControl(paneControls.set(driver: .none, for: pane), to: pane)
    refreshExecStatus(of: pane)
    refreshControlMarks()
  }

  /// A pane left the window. Its driver's authority ends at once, since nothing names the
  /// attachment any more. The applet's own close shuts the child down.
  func execPaneClosed(_ pane: NodeID) {
    execAttachments[pane] = nil
    launchAuthority.paneClosed(ExecLaunchAuthority.Target(window: scriptWindowID, pane: pane))
  }

  /// What the pane's exec strip shows now.
  func execStatus(of pane: NodeID) -> PaneExecStatus? {
    guard let attachment = execAttachments[pane] else { return nil }

    let program = attachment.program

    switch attachment.state {
    case .idle(let note):
      return PaneExecStatus(text: "Driver \(program): \(note)", action: "Run")

    case .waitingForValues:
      return PaneExecStatus(text: "Driver \(program) needs its environment values.", action: nil)

    case .waitingForApproval:
      return PaneExecStatus(
        text: "Driver \(program) waits for approval in Window > Pending Requests.", action: nil)

    case .running:
      return PaneExecStatus(text: "Driver \(program) is running.", action: nil)

    case .ended(let reason):
      return PaneExecStatus(text: "Driver \(program): \(reason)", action: "Restart")
    }
  }

  func refreshExecStatus(of pane: NodeID) {
    paneArea.paneView(for: pane)?.execStatus = execStatus(of: pane)
  }
}

/// Why a pane cannot take an exec driver.
enum ExecPaneError: Error, Equatable {
  case notOpen
  case unsupported(String)
}

/// Asks for the values of a driver's environment keys in a sheet. Each field is secure, since a
/// value is often a token.
@MainActor
enum ExecValuesSheet {
  static func present(keys: [String], program: String, window: NSWindow?) async -> [String: String]?
  {
    guard let window else { return nil }

    let alert = NSAlert()
    let stack = NSStackView()
    var fields: [(String, NSSecureTextField)] = []

    stack.orientation = .vertical
    stack.alignment = .leading

    for key in keys {
      let label = NSTextField(labelWithString: key)
      let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))

      field.setAccessibilityIdentifier("exec-value-\(key)")
      field.widthAnchor.constraint(equalToConstant: 260).isActive = true
      stack.addArrangedSubview(label)
      stack.addArrangedSubview(field)
      fields.append((key, field))
    }

    stack.frame = NSRect(x: 0, y: 0, width: 260, height: CGFloat(keys.count) * 48)

    alert.messageText = "Values for \(program)"
    alert.informativeText =
      "The driver needs these environment variables. They are kept only while this pane is open, "
      + "and never saved."
    alert.accessoryView = stack
    alert.addButton(withTitle: "Continue")
    alert.addButton(withTitle: "Cancel")

    let response = await alert.beginSheetModal(for: window)

    guard response == .alertFirstButtonReturn else { return nil }

    return Dictionary(uniqueKeysWithValues: fields.map { ($0.0, $0.1.stringValue) })
  }
}
