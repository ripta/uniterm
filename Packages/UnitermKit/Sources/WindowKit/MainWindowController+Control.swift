import AppKit
import AppletKit
import LayoutKit
import PaneModel

// MARK: Pane control

extension MainWindowController {
  /// The pane's control as the window holds it.
  func control(of pane: NodeID) -> PaneControl {
    paneControls.control(of: pane)
  }

  /// The combinations the pane's applet type supports. A pane with no applet, or one whose type
  /// declares nothing, supports only disconnected access.
  func supportedControl(of pane: NodeID) -> Set<ControlCombination> {
    guard let applet = paneArea.applet(for: pane) else { return [.disconnected] }

    return AppletTypeDeclaration.supportedControl(forType: applet.typeID, in: appletTypes)
  }

  /// True when the user can enable remote control on the pane: it is disconnected now, and its
  /// applet type supports remote control with the driver the pane has now.
  func canEnableRemoteControl(_ pane: NodeID?) -> Bool {
    guard let pane, contains(pane: pane) else { return false }

    let control = control(of: pane)

    return control.access == .disconnected
      && supportedControl(of: pane).contains(
        ControlCombination(access: .remoteControlled, driver: control.driver))
  }

  func canDisconnect(_ pane: NodeID?) -> Bool {
    guard let pane, contains(pane: pane) else { return false }

    return control(of: pane).access == .remoteControlled
  }

  func canRevokeController(_ pane: NodeID?) -> Bool {
    guard let pane, contains(pane: pane) else { return false }

    return !controllers(of: pane).isEmpty
  }

  /// The controllers that have authority over the pane: the owners of the groups that hold it as
  /// a member or as their source, and the connections that act for it.
  func controllers(of pane: NodeID) -> Set<UInt64> {
    var found = Set<UInt64>()

    for group in paneArea.tree.enclosingGroups(of: pane) {
      guard let owner = group.owner, group.members.contains(pane) || group.source == pane
      else { continue }

      found.insert(owner.connection)
    }

    if let controllerAuthority {
      found.formUnion(controllerAuthority.controllers(actingFrom: scriptWindowID, pane: pane))
    }

    return found
  }

  /// The live owner of the innermost group the pane is a member of, when there is one.
  func owner(of pane: NodeID) -> GroupOwner? {
    paneArea.tree.enclosingGroups(of: pane).last { $0.members.contains(pane) }?.owner
  }

  /// Lets programs the trust rules allow drive the pane. Only the user does this, and only on a
  /// pane whose applet type supports it.
  ///
  /// The applet takes its new control before the window records the mode, so its clipboard policy
  /// is in place before any call can reach the pane. Both happen on the main actor with nothing
  /// suspended between them.
  func enableRemoteControl(_ pane: NodeID?) {
    guard let pane, canEnableRemoteControl(pane), let applet = paneArea.applet(for: pane) else {
      return
    }

    var table = paneControls
    let control = table.set(.remoteControlled, for: pane)

    applet.controlDidChange(control)
    paneControls = table

    refreshControlMarks()
    onLayoutChange?()
  }

  /// Refuses every other program's call to the pane from now on. A call that waits for the pane,
  /// or that the app has not read yet, checks again when it runs, so it is refused too. The
  /// pane's own outbound calls to panes its controller owns are not affected.
  func disconnect(_ pane: NodeID?) {
    guard let pane, contains(pane: pane) else { return }

    let control = paneControls.set(.disconnected, for: pane)

    paneArea.applet(for: pane)?.controlDidChange(control)
    refreshControlMarks()
    onLayoutChange?()
  }

  /// Ends the authority of every controller over the pane: its live grant, its calls still
  /// waiting, and the groups it owns, in every window. The groups and their panes stay, with no
  /// owner. The pane's own mode stays as it is.
  func revokeController(_ pane: NodeID?) {
    guard let pane, contains(pane: pane) else { return }

    let ids = controllers(of: pane)

    guard !ids.isEmpty else { return }

    controllerAuthority?.revokeControllers(ids)

    for id in ids { controllerEnded(id) }

    pushControl(paneControls.bump(pane), to: pane)
    refreshControlMarks()
  }

  /// A controller's authority ended. Its groups in this window lose their owner, and each pane
  /// that was a member gets a new generation, so a permission asked under the controller is stale.
  func controllerEnded(_ id: UInt64) {
    let released = paneArea.releaseOwner(GroupOwner(connection: id))

    for pane in released where contains(pane: pane) {
      pushControl(paneControls.bump(pane), to: pane)
    }

    refreshControlMarks()
  }

  func pushControl(_ control: PaneControl, to pane: NodeID) {
    paneArea.applet(for: pane)?.controlDidChange(control)
  }

  func runControlAction(_ action: PaneControlAction, on pane: NodeID) {
    switch action {
    case .enable: enableRemoteControl(pane)
    case .disconnect: disconnect(pane)
    case .revoke: revokeController(pane)
    }
  }

  /// What a saved layout keeps of the pane's control: the mode it has now, or the intent it was
  /// restored with while the user has left it disconnected, and its exec declaration with no
  /// environment value.
  func savedControl(of pane: NodeID) -> SavedPaneControl {
    let control = control(of: pane)
    let access =
      control.access == .disconnected
      ? paneControls.intent(of: pane)?.access ?? .disconnected : control.access

    return SavedPaneControl(
      access: access, driver: .none, exec: execAttachments[pane]?.declaration)
  }

  private func savedIntent(of pane: NodeID) -> PaneAccessMode? {
    guard let access = paneControls.intent(of: pane)?.access, access != .disconnected else {
      return nil
    }

    return access
  }

  /// Tells every pane's badge what to show.
  func refreshControlMarks() {
    for pane in paneArea.tree.paneIDs {
      paneArea.paneView(for: pane)?.controlMark = controlMark(for: pane)
    }
  }

  /// The badge's mark for a pane, from the control table, the tree, and the live controllers.
  func controlMark(for pane: NodeID) -> PaneControlMark {
    let control = control(of: pane)
    let memberships = paneArea.tree.enclosingGroups(of: pane).filter { $0.members.contains(pane) }
    let owner = memberships.last?.owner

    var mark = PaneControlMark(
      access: control.access, driver: control.driver,
      owner: owner.map(controllerName),
      inUnownedGroup: !memberships.isEmpty && owner == nil,
      savedIntent: control.access == .disconnected ? savedIntent(of: pane) : nil,
      enableAvailable: canEnableRemoteControl(pane), revokeAvailable: canRevokeController(pane))

    mark.controllers = controllers(of: pane).sorted().map {
      controllerName(GroupOwner(connection: $0))
    }

    return mark
  }

  private func controllerName(_ owner: GroupOwner) -> String {
    controllerAuthority?.controllerName(owner.connection) ?? "\(owner)"
  }
}
