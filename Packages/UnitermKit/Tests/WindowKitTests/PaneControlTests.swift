import AppKit
import AppletKit
import LayoutKit
import PaneModel
import ScriptHost
import ScriptWire
import XCTest

@testable import WindowKit

/// Pane control as the window holds it and as a script meets it: the default mode, the local
/// actions and the badge, scope over the pane tree, disconnect and revoke, nearest selection, and
/// what a saved layout keeps. Real windows and the real host API run over fake applets.
///
/// The script acts for the first pane, connection 1, unless a test names another caller. These
/// cannot prove what a person sees on screen. `PaneControlUITests` drives the badge in the app.
@MainActor
final class PaneControlTests: XCTestCase {
  private func makeFixture(
    directoryExists: @escaping @Sendable (String) -> Bool = { _ in true }
  ) -> ScriptingFixture {
    let fixture = ScriptingFixture(directoryExists: directoryExists)
    addTeardownBlock { @MainActor in fixture.cleanUp() }
    return fixture
  }

  private func fields(_ value: ScriptValue) -> [String: ScriptValue] {
    guard case .record(let fields) = value else { return [:] }

    return fields
  }

  private func listedPanes(_ value: ScriptValue) -> [UInt64] {
    guard case .array(let entries) = value else { return [] }

    return entries.compactMap {
      guard case .integer(let pane)? = fields($0)["pane"] else { return nil }

      return pane
    }
  }

  private func expectError(
    _ kind: ScriptFailureKind, _ fragment: String? = nil, file: StaticString = #filePath,
    line: UInt = #line, _ body: () async throws -> Any
  ) async {
    do {
      let value = try await body()
      XCTFail("the call succeeded with \(value)", file: file, line: line)
    } catch let error as ScriptCallError {
      XCTAssertEqual(error.kind, kind, error.text, file: file, line: line)

      if let fragment {
        XCTAssertTrue(error.text.contains(fragment), error.text, file: file, line: line)
      }
    } catch {
      XCTFail("the call threw \(error)", file: file, line: line)
    }
  }

  private func reference(_ controller: MainWindowController, _ pane: NodeID)
    -> ScriptPaneReference
  {
    ScriptPaneReference(window: controller.scriptWindowID, pane: pane.rawValue)
  }

  // MARK: Defaults and local actions

  /// Catches a new pane that starts with control, or whose applet starts before it learns its
  /// mode. A pane the user splits off and the first pane both start disconnected, with no badge.
  func testNewUserPanesStartDisconnectedWithNoBadge() throws {
    let fixture = makeFixture()
    let (controller, _) = try fixture.openWindow(enabled: false)
    let split = try XCTUnwrap(controller.openPane(.dataViewer, axis: .row))

    for pane in controller.paneIDs {
      XCTAssertEqual(controller.control(of: pane).access, .disconnected)
      XCTAssertTrue(try XCTUnwrap(controller.paneArea.paneView(for: pane)).controlBadge.isHidden)
    }

    let applet = try XCTUnwrap(controller.paneArea.applet(for: split) as? FakeApplet)

    XCTAssertEqual(applet.controlAtStart?.access, .disconnected)
  }

  /// Catches a remote-controlled pane with no marker, a badge that cannot be found, and an applet
  /// that learns of its control only after the window records it. The badge names the mode, and
  /// the actions it offers follow the mode.
  func testEnablingShowsTheBadgeAndTellsTheAppletFirst() throws {
    let fixture = makeFixture()
    let (controller, _) = try fixture.openWindow(enabled: false)
    let pane = controller.focusedPane
    let applet = try XCTUnwrap(fixture.made.first)
    let view = try XCTUnwrap(controller.paneArea.paneView(for: pane))

    XCTAssertTrue(controller.canEnableRemoteControl(pane))

    XCTAssertTrue(controller.commands.run(.enableRemoteControl, in: controller.commandContext()))

    XCTAssertEqual(applet.controls.last?.access, .remoteControlled)
    XCTAssertEqual(controller.control(of: pane), applet.controls.last)
    XCTAssertFalse(view.controlBadge.isHidden)
    XCTAssertEqual(view.controlBadge.accessibilityIdentifier(), "pane-control-\(pane)")
    XCTAssertEqual(view.controlBadge.accessibilityValue() as? String, "remote-controlled")
    XCTAssertFalse(controller.canEnableRemoteControl(pane))
    XCTAssertTrue(controller.canDisconnect(pane))

    let titles = view.controlMenu().items.filter(\.isEnabled).map(\.title)

    XCTAssertEqual(titles, ["Disconnect"])

    view.onControlAction?(.disconnect)

    XCTAssertEqual(controller.control(of: pane).access, .disconnected)
    XCTAssertEqual(applet.controls.last?.access, .disconnected)
    XCTAssertTrue(view.controlBadge.isHidden)
  }

  /// Catches a control action that an applet's own keys can reach, or that waits for a sheet the
  /// applet put up. The actions have no key, and the badge's menu works while a sheet shows.
  func testTheControlActionsNeedNoKeyAndWorkWhileASheetShows() throws {
    let fixture = makeFixture()
    let (controller, _) = try fixture.openWindow(enabled: false)
    let window = try XCTUnwrap(controller.window)

    window.orderFrontRegardless()

    let sheet = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled],
      backing: .buffered, defer: false)

    window.beginSheet(sheet, completionHandler: nil)
    defer { window.endSheet(sheet) }

    for id in [CommandID.enableRemoteControl, .disconnectPane, .revokeController] {
      let command = try XCTUnwrap(controller.commands.command(id))

      XCTAssertNil(command.key, "\(id) has a key")
      XCTAssertNotNil(command.menu, "\(id) has no menu item")
    }

    controller.paneArea.paneView(for: controller.focusedPane)?.onControlAction?(.enable)

    XCTAssertEqual(controller.control(of: controller.focusedPane).access, .remoteControlled)
  }

  /// Catches remote control on a pane whose type declares none. A window that knows no type
  /// leaves every pane disconnected-only.
  func testATypeThatDeclaresNoRemoteControlCannotBeEnabled() throws {
    let fixture = makeFixture()
    let (controller, _) = try fixture.openWindow(enabled: false)
    let pane = controller.focusedPane
    let launcher = try XCTUnwrap(controller.openLauncher(axis: .row))
    let first = try XCTUnwrap(fixture.made.first)

    first.typeID = "undeclared"

    XCTAssertFalse(controller.canEnableRemoteControl(pane))

    controller.enableRemoteControl(pane)

    XCTAssertEqual(controller.control(of: pane).access, .disconnected)
    XCTAssertTrue(controller.canEnableRemoteControl(launcher), "the fixture declares the launcher")
  }

  /// Catches a question that names the applet's title, which follows the selected tab, when the
  /// applet says another part of the pane asked. A permission names it the same way.
  func testAQuestionNamesWhatAskedAndNotTheSelectedTab() async throws {
    let fixture = makeFixture()
    let (controller, _) = try fixture.openWindow(enabled: false)
    let applet = try XCTUnwrap(fixture.made.first)
    var details: [String] = []

    applet.title = "selected-tab"
    controller.confirmer = { question, _ in
      details.append(question.detail)
      return false
    }
    controller.permissionAsker = { request, _ in
      details.append(request.detail)
      return .deny
    }

    _ = await controller.applet(
      applet,
      confirm: AppletConfirmation(
        title: "t", detail: "d", confirmTitle: "a", cancelTitle: "b", subject: "background-tab"))
    _ = await controller.applet(
      applet,
      askPermission: AppletPermissionRequest(
        title: "t", detail: "d", subject: "background-tab", sessionTitle: "s"))

    XCTAssertEqual(details.count, 2)

    for detail in details {
      XCTAssertTrue(detail.contains("background-tab"), detail)
      XCTAssertFalse(detail.contains("selected-tab"), detail)
    }
  }

  // MARK: What a disconnected source may do

  /// Catches a caller in a disconnected pane that learns more than its binding, opens anything,
  /// or meets a dialog. Every other call says how the user enables the pane.
  func testADisconnectedSourceGetsOnlyItsBindingAndTheEnableAction() async throws {
    let fixture = makeFixture()
    let (controller, pane) = try fixture.openWindow(enabled: false)

    let listed = try fixture.listWindows()

    guard case .array(let entries) = listed, let entry = entries.first.map(fields) else {
      return XCTFail("no binding in \(listed)")
    }

    XCTAssertEqual(entries.count, 1)
    XCTAssertEqual(Set(entry.keys), ["window", "pane", "control"])
    XCTAssertEqual(entry["control"], .string("disconnected"))

    await expectError(.refused, "Enable Remote Control") {
      try fixture.listPanes(window: pane.window)
    }

    await expectError(.refused, "Enable Remote Control") {
      try await fixture.openPane(kind: "terminal", beside: pane, axis: nil, directory: nil)
    }

    await expectError(.refused, "Enable Remote Control") {
      try await fixture.openPane(kind: "terminal", target: .nearest(kind: "fake"))
    }

    XCTAssertEqual(controller.paneIDs.count, 1)
    XCTAssertEqual(fixture.made.count, 1)
    XCTAssertNil(controller.window?.attachedSheet)
  }

  /// Catches a disconnected source that loses the panes it owns, or that can still rearrange its
  /// own pane. It keeps outbound calls to its members and cannot split itself.
  func testADisconnectedSourceKeepsItsMembersButCannotRearrangeItself() async throws {
    let fixture = makeFixture()
    fixture.make = {
      let applet = FakeApplet()
      applet.canOpenTab = true
      return applet
    }

    let (controller, pane) = try fixture.openWindow()
    let member = try await fixture.openOwned(beside: pane)

    controller.disconnect(pane.pane.node)

    XCTAssertEqual(listedPanes(try fixture.listPanes(window: pane.window)), [member.rawValue])

    _ = try await fixture.openTab(pane: reference(controller, member), directory: nil)

    await expectError(.refused, "disconnected") {
      try await fixture.openPane(kind: "terminal", beside: pane, axis: nil, directory: nil)
    }

    XCTAssertEqual(controller.paneIDs.count, 2)
  }

  // MARK: Scope

  /// Catches a program that controls an ancestor or an unrelated sibling. A second controller acts
  /// from a member of the first one's group. It cannot reach the group's source, another member,
  /// or a remote-controlled pane the user opened, but it reaches its own members. The first
  /// controller keeps its members, and gains nothing over the second one's.
  func testAProgramReachesOnlyItsOwnPaneAndItsOwnMembers() async throws {
    let fixture = makeFixture()
    let (controller, pane) = try fixture.openWindow()

    let first = try await fixture.openOwned(beside: pane)
    let sibling = try await fixture.openOwned(beside: reference(controller, first))
    let user = try XCTUnwrap(controller.openPane(.dataViewer, axis: .column, from: pane.pane.node))

    controller.enableRemoteControl(user)

    let second = ScriptCaller(connection: 2, window: pane.window, pane: first)
    let theirs = try await fixture.openOwned(beside: reference(controller, first), as: second)

    for target in [pane.pane.node, sibling, user] {
      await expectError(.notFound, "not open") {
        try fixture.prepareSend(to: self.reference(controller, target), as: second)
      }
    }

    XCTAssertEqual(
      Set(listedPanes(try fixture.listPanes(window: pane.window, as: second))),
      [first.rawValue, theirs.rawValue])
    XCTAssertEqual(
      Set(listedPanes(try fixture.listPanes(window: pane.window))),
      [pane.pane, first.rawValue, sibling.rawValue])

    await expectError(.notFound, "not open") {
      try fixture.prepareSend(to: self.reference(controller, theirs))
    }

    await expectError(.notFound, "window is not open") {
      try fixture.prepareSend(to: ScriptPaneReference(window: pane.window + 1, pane: pane.pane))
    }
  }

  /// Catches a user split that adds a pane to a controller's group. The new pane sits beside the
  /// member but is no one's, so the controller cannot reach it even once it is enabled.
  func testAUserSplitOfAMemberIsOutsideTheGroup() async throws {
    let fixture = makeFixture()
    let (controller, pane) = try fixture.openWindow()
    let member = try await fixture.openOwned(beside: pane)

    let split = try XCTUnwrap(controller.openPane(.dataViewer, axis: .column, from: member))

    controller.enableRemoteControl(split)

    XCTAssertNil(controller.owner(of: split))
    XCTAssertEqual(controller.owner(of: member), GroupOwner(connection: 1))

    await expectError(.notFound) {
      try fixture.prepareSend(to: self.reference(controller, split))
    }
  }

  // MARK: Disconnect and revoke

  /// Catches a call queued for a pane that keeps its effect after the pane is disconnected. The
  /// call waits in its directory check while the user disconnects the target, and nothing opens.
  func testDisconnectRefusesACallQueuedForThePane() async throws {
    let gate = DispatchSemaphore(value: 0)
    let fixture = makeFixture(directoryExists: { _ in
      _ = gate.wait(timeout: .now() + 10)
      return true
    })

    fixture.make = {
      let applet = FakeApplet()
      applet.canOpenTab = true
      return applet
    }

    let (controller, pane) = try fixture.openWindow()
    let member = try await fixture.openOwned(beside: pane)
    let applet = try XCTUnwrap(controller.paneArea.applet(for: member) as? FakeApplet)

    let call = Task { @MainActor in
      try await fixture.openTab(pane: self.reference(controller, member), directory: "/synthetic")
    }

    await Task.yield()
    controller.disconnect(member)
    gate.signal()

    do {
      _ = try await call.value
      XCTFail("a call to a disconnected pane opened a tab")
    } catch let error as ScriptCallError {
      XCTAssertEqual(error.kind, .refused, error.text)
    }

    XCTAssertEqual(applet.tabCount, 1)
  }

  /// Catches a revoke that leaves the controller its groups, drops the group or its pane, or
  /// leaves a permission asked under the old owner current. The group stays with no owner, the
  /// member keeps its mode, and its applet gets a new generation.
  func testRevokeRemovesTheControllersGroupAuthorityAndKeepsTheGroup() async throws {
    let fixture = makeFixture()
    let (controller, pane) = try fixture.openWindow()
    let member = try await fixture.openOwned(beside: pane)
    let applet = try XCTUnwrap(controller.paneArea.applet(for: member) as? FakeApplet)
    let before = try XCTUnwrap(applet.controls.last)

    XCTAssertTrue(controller.canRevokeController(member))

    controller.revokeController(member)

    XCTAssertNil(controller.owner(of: member))
    XCTAssertEqual(controller.paneArea.tree.groups.count, 1)
    XCTAssertTrue(controller.contains(pane: member))
    XCTAssertEqual(controller.control(of: member).access, .remoteControlled)
    XCTAssertGreaterThan(try XCTUnwrap(applet.controls.last).generation, before.generation)
    XCTAssertFalse(controller.canRevokeController(member))
    XCTAssertEqual(
      controller.paneArea.paneView(for: member)?.controlMark?.inUnownedGroup, true)

    await expectError(.notFound) {
      try fixture.prepareSend(to: self.reference(controller, member))
    }
  }

  // MARK: Opening

  /// Catches a combination the applet type does not declare that is checked only after the pane
  /// or its applet exists. Nothing is built, and the directory is never checked.
  func testAnUnsupportedAccessIsRefusedBeforeAnythingOpens() async throws {
    let checked = Checks()
    let fixture = makeFixture(directoryExists: { _ in
      checked.count += 1
      return true
    })
    let (controller, pane) = try fixture.openWindow()

    await expectError(.refused, "does not support remote-controlled") {
      try await fixture.openPane(
        kind: "data-viewer", beside: pane, axis: nil, directory: "/synthetic",
        access: .remoteControlled)
    }

    XCTAssertEqual(fixture.made.count, 1)
    XCTAssertEqual(controller.paneIDs.count, 1)
    XCTAssertEqual(checked.count, 0)
  }

  /// Catches a remote-controlled pane a script opens whose applet starts before it knows.
  func testAPaneOpenedRemoteControlledHasItsControlBeforeItStarts() async throws {
    let fixture = makeFixture()
    let (controller, pane) = try fixture.openWindow()
    let member = try await fixture.openOwned(beside: pane)
    let applet = try XCTUnwrap(controller.paneArea.applet(for: member) as? FakeApplet)

    XCTAssertEqual(applet.controlAtStart?.access, .remoteControlled)
    XCTAssertFalse(try XCTUnwrap(controller.paneArea.paneView(for: member)).controlBadge.isHidden)
  }

  // MARK: Nearest

  /// Catches a nearest pick that ranks before it filters, breaks a tie by anything but reading
  /// order, or opens a pane when nothing matches.
  ///
  /// The user splits a viewer off the source, so it is the nearest viewer by edges. It is not the
  /// caller's, so the first member wins, and the two members tie on distance. Each pick is made
  /// again when the call runs.
  func testNearestFiltersByAuthorityThenRanksByTreeDistanceAndNeverOpens() async throws {
    let fixture = makeFixture()
    let (controller, pane) = try fixture.openWindow()

    fixture.make = {
      let applet = FakeApplet()
      applet.typeID = "viewer"
      return applet
    }

    let first = try await fixture.openOwned(beside: pane)
    let second = try await fixture.openOwned(beside: reference(controller, first))
    let user = try XCTUnwrap(controller.openPane(.dataViewer, axis: .column, from: pane.pane.node))

    controller.enableRemoteControl(user)

    let distances = controller.paneArea.tree.edgeDistances(from: pane.pane.node)

    XCTAssertLessThan(try XCTUnwrap(distances[user]), try XCTUnwrap(distances[first]))
    XCTAssertEqual(distances[first], distances[second])

    let caller = fixture.caller

    XCTAssertEqual(fixture.scripting.nearest("viewer", to: caller, in: controller), first)

    let sent = try fixture.scripting.prepareSend(to: .nearest(kind: "viewer"), caller: caller)

    XCTAssertEqual(sent.pane, first.rawValue)

    controller.disconnect(first)

    XCTAssertEqual(fixture.scripting.nearest("viewer", to: caller, in: controller), second)

    controller.disconnect(second)

    let made = fixture.made.count
    let panes = controller.paneIDs.count

    await expectError(.notFound, "no viewer pane") {
      try fixture.scripting.prepareSend(to: .nearest(kind: "viewer"), caller: caller)
    }

    await expectError(.notFound, "no viewer pane") {
      try await fixture.openPane(kind: "terminal", target: .nearest(kind: "viewer"))
    }

    XCTAssertEqual(fixture.made.count, made)
    XCTAssertEqual(controller.paneIDs.count, panes)
  }

  // MARK: Saved layouts

  /// Catches a saved layout that drops a group or a pane's mode, and a restore that brings back an
  /// owner or a live mode. The restored window shows the saved mode as inactive intent, and saves
  /// it again until the user acts.
  func testALayoutSavesIntentAndRestoresEverythingDisconnected() async throws {
    let fixture = makeFixture()
    let (controller, pane) = try fixture.openWindow()
    let member = try await fixture.openOwned(beside: pane)

    let saved = try XCTUnwrap(controller.savedWindow())

    guard case .group(let group, let source, let members, let inner) = saved.tree else {
      return XCTFail("the saved tree has no group: \(saved.tree)")
    }

    XCTAssertEqual(source, pane.pane.node)
    XCTAssertEqual(members, [member])
    XCTAssertEqual(
      inner.paneIDs.map { controlOf($0, in: inner) },
      [.remoteControlled, .remoteControlled])

    let restored = try fixture.windows.open(restoring: RestoredWindow(saved: saved))
    restored.window?.contentView?.layoutSubtreeIfNeeded()

    XCTAssertEqual(restored.paneArea.tree.groups.map(\.id), [group])
    XCTAssertEqual(restored.paneArea.tree.groups.map(\.owner), [nil])

    for id in restored.paneIDs {
      XCTAssertEqual(restored.control(of: id).access, .disconnected)
      XCTAssertEqual(
        restored.paneArea.paneView(for: id)?.controlMark?.savedIntent, .remoteControlled)
    }

    let again = try XCTUnwrap(restored.savedWindow())

    XCTAssertEqual(again.tree, saved.tree)

    restored.disconnect(member)

    XCTAssertNil(restored.paneArea.paneView(for: member)?.controlMark?.savedIntent)
  }

  private func controlOf(_ pane: NodeID, in node: SavedNode) -> PaneAccessMode? {
    switch node {
    case .pane(let id, _, let control): return id == pane ? control.access : nil
    case .split(_, _, let children):
      return children.lazy.compactMap { self.controlOf(pane, in: $0.node) }.first
    case .group(_, _, _, let inner): return controlOf(pane, in: inner)
    }
  }
}

private final class Checks: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0

  var count: Int {
    get {
      lock.lock()
      defer { lock.unlock() }
      return value
    }
    set {
      lock.lock()
      value = newValue
      lock.unlock()
    }
  }
}

extension UInt64 {
  fileprivate var node: NodeID { NodeID(rawValue: self) }
}
