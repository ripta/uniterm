import AppKit
import AppletKit
import ExecDriver
import PaneModel
import ScriptHost
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

  /// The owner the running driver's groups have. Each run gets its own, and loses it when it ends,
  /// so a later run never inherits an earlier run's groups.
  var owner: GroupOwner?

  /// True once the user revoked this run's control of other panes. It holds for the rest of the
  /// run, as a revoke holds for a connection, so the run lays out and commands nothing beyond its
  /// own pane again, layouts still in preparation included. A new run starts clear.
  var revoked = false

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
    lastDriverOwner += 1

    let run = attachment.run
    let owner = GroupOwner(driver: lastDriverOwner)

    attachment.owner = owner
    attachment.revoked = false
    pushControl(paneControls.set(driver: .exec, for: pane), to: pane)

    let drives: @MainActor () -> Bool = { [weak self, weak attachment] in
      guard let self, let attachment else { return false }

      return execAttachments[pane] === attachment && attachment.run == run
        && contains(pane: pane)
    }

    let beyond: @MainActor () -> ScriptCallError? = { [weak self, weak attachment] in
      guard let self, let attachment, drives(), attachment.owner == owner else {
        return .refused("the driver no longer drives this pane")
      }

      guard !attachment.revoked else {
        return .refused(
          "You revoked this driver's control of other panes. It keeps its own pane, and needs a "
            + "new run to act beyond it.")
      }

      return sourceRefusal(pane)
    }

    let channel = ExecDriverChannel(
      launch: launch, environment: environment, applet: applet, dispatcher: dispatcher,
      authority: {
        drives() ? nil : AppletCommandError(.refused, "the driver no longer drives this pane")
      },
      producer: statusCenter.issueProducer(kind: .applet, name: "\(attachment.program) (driver)"),
      killGrace: execKillGrace,
      host: { [weak self] request, reply in
        guard let self else {
          return reply(.failure(AppletCommandError(.refused, "uniterm is quitting")))
        }

        if let refusal = beyond() { return reply(.failure(Self.driverFailure(refusal))) }

        driverAsked(request, from: pane, as: owner, beyond: beyond, reply: reply)
      },
      onEnd: { [weak self, weak attachment] end in
        guard let self, let attachment else { return }

        driverEnded(end, attachment: attachment, run: run, pane: pane)
      })

    attachment.state = .running(channel)

    do {
      try channel.start()
    } catch {
      attachment.state = .ended("The driver did not start: \(error).")
      attachment.owner = nil
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
    releaseDriverOwner(of: attachment)
    pushControl(paneControls.set(driver: .none, for: pane), to: pane)
    refreshExecStatus(of: pane)
    refreshControlMarks()
  }

  /// A run's groups lose their owner when the run ends, however it ends.
  private func releaseDriverOwner(of attachment: ExecAttachment) {
    guard let owner = attachment.owner else { return }

    attachment.owner = nil
    ownerEnded(owner)
  }

  /// A pane left the window. Its driver's authority ends at once, since nothing names the
  /// attachment any more, and so does its authority over the groups it owns. The applet's own
  /// close shuts the child down.
  func execPaneClosed(_ pane: NodeID) {
    if let attachment = execAttachments.removeValue(forKey: pane) {
      releaseDriverOwner(of: attachment)
    }

    launchAuthority.paneClosed(ExecLaunchAuthority.Target(window: scriptWindowID, pane: pane))
  }

  // MARK: What a driver asks of the window

  /// Answers a driver's layout request or its command to another pane. `beyond` says why the run
  /// may not act beyond its own pane now, and is asked again at every authority check. A command
  /// reaches only a remote-controlled member of a group this run owns, and its authority is
  /// checked again when it is delivered.
  private func driverAsked(
    _ request: ExecDriverChannel.HostRequest, from pane: NodeID, as owner: GroupOwner,
    beyond: @escaping @MainActor () -> ScriptCallError?, reply: @escaping ControlDispatcher.Reply
  ) {
    switch request {
    case .layout(let layout):
      Task { @MainActor [weak self] in
        guard let self else { return }

        do {
          let parsed = try LayoutRequest.parse(
            layout, window: scriptWindowID, declarations: appletTypes)

          let panes = try await requestLayout(
            parsed, anchor: pane, owner: owner,
            authorize: { [self] in
              if let refusal = beyond() { throw refusal }

              try checkPlacedPanes(of: parsed) { $0 == pane || owns($0, owner) }
            },
            directoryExists: directoryExists)

          reply(
            .success(
              .object([
                "window": .number(Double(scriptWindowID)),
                "panes": .array(panes.map { .number(Double($0.rawValue)) }),
              ])))
        } catch {
          reply(.failure(Self.driverFailure(error)))
        }
      }

    case .command(let target, let submission):
      let member = NodeID(rawValue: target)

      let authority: ControlDispatcher.Authority = { [weak self] in
        guard let self else { return AppletCommandError(.refused, "uniterm is quitting") }

        if let refusal = beyond() { return Self.driverFailure(refusal) }

        guard contains(pane: member), owns(member, owner) else {
          return AppletCommandError(.notFound, "the pane is not open in that window")
        }

        guard control(of: member).access == .remoteControlled else {
          return AppletCommandError(
            .refused, "The pane is disconnected. The user must enable remote control on it.")
        }

        return nil
      }

      guard authority() == nil, let applet = paneArea.applet(for: member) else {
        return reply(
          .failure(
            authority() ?? AppletCommandError(.notFound, "the pane is not open in that window")))
      }

      let generation = control(of: member).generation

      dispatcher.submit(
        submission, to: applet,
        authority: { [weak self, weak applet] in
          if let refusal = authority() { return refusal }

          guard let self, let applet, paneArea.applet(for: member) === applet,
            control(of: member).generation == generation
          else {
            return AppletCommandError(
              .refused, "the pane's control changed after the command was sent")
          }

          return nil
        },
        reply: reply)
    }
  }

  /// A driver acts beyond its own pane only while the user has that pane remote-controlled.
  private func sourceRefusal(_ pane: NodeID) -> ScriptCallError? {
    guard contains(pane: pane) else { return .notFound("the driver's pane is closed") }

    guard control(of: pane).access == .remoteControlled else {
      return .refused(
        "This driver's pane is disconnected, so it cannot lay out or command other panes. To "
          + "allow it, choose Enable Remote Control from the pane's control badge or the File "
          + "menu.")
    }

    return nil
  }

  /// True when the pane is a member of a group `owner` owns. Nesting grants nothing.
  private func owns(_ pane: NodeID, _ owner: GroupOwner) -> Bool {
    paneArea.tree.enclosingGroups(of: pane).contains {
      $0.owner == owner && $0.members.contains(pane)
    }
  }

  private static func driverFailure(_ error: any Error) -> AppletCommandError {
    guard let error = error as? ScriptCallError else {
      return AppletCommandError(.failed, "\(error)")
    }

    switch error.kind {
    case .badArgument: return AppletCommandError(.badArgument, error.text)
    case .notFound: return AppletCommandError(.notFound, error.text)
    case .unsupported: return AppletCommandError(.unsupportedApplet, error.text)
    case .refused: return AppletCommandError(.refused, error.text)
    case .busy: return AppletCommandError(.busy, error.text)
    case .failed, .replyLost: return AppletCommandError(.failed, error.text)
    }
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
