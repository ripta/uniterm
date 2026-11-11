import AppKit
import AppletFixtures
import AppletKit
import ExecDriver
import ExecTestSupport
import LayoutKit
import PaneModel
import Preferences
import ScriptHost
import ScriptWire
import XCTest

@testable import WindowKit

/// Real windows whose panes hold hosted fixtures, a real driver process, and the window side of
/// the host API. Every pane is a slides fixture, except one the test opens as a fake applet that
/// takes no commands.
///
/// These prove the pane's exec driver from Run to end: execution authority, launch inputs, shared
/// dispatch with remote callers, the disconnected rule, restore, and close. They cannot prove the
/// chrome on screen or the panel's buttons. The UI tests drive those.
@MainActor
final class ExecPaneFixture {
  let suite = "uniterm-exec-test-\(UUID().uuidString)"
  let defaults: UserDefaults
  let windows: WindowSet
  let scripting: WindowScripting
  let scratch: URL

  /// The kind of applet the next pane gets.
  var nextIsFake = false

  /// What the values sheet answers, and the keys it was asked for.
  var values: [String: String]? = [:]
  private(set) var askedKeys: [[String]] = []

  static let declarations =
    AppletFixtures.declarations + [
      AppletTypeDeclaration(
        typeID: "fake", displayName: "Fake", symbolName: "questionmark", opens: [],
        controlSupport: [.remoteControlled])
    ]

  init() throws {
    let defaults = UserDefaults(suiteName: suite)!
    let store = SettingsStore(defaults: defaults)
    let appearance = AppearanceController(store: store)

    self.defaults = defaults
    scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
      "exec-pane-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

    var factory: AppletFactory = { _, _ in SlidesFixture() }

    windows = WindowSet(
      visibleFrame: { _ in NSRect(x: 0, y: 0, width: 4000, height: 3000) },
      makeRestoredController: { identifier, restored in
        try MainWindowController(
          appearance: appearance, settings: store, identifier: identifier,
          appletTypes: ExecPaneFixture.declarations, restoring: restored,
          restoreApplet: { try AppletFixtures.restore($0) },
          makeApplet: { choice, directory in try factory(choice, directory) }
        ).detachFromRealScreen()
      },
      makeController: { identifier, directory in
        try MainWindowController(
          appearance: appearance, settings: store, identifier: identifier, startingIn: directory,
          appletTypes: ExecPaneFixture.declarations,
          makeApplet: { choice, directory in try factory(choice, directory) }
        ).detachFromRealScreen()
      })

    scripting = WindowScripting(windows: windows)

    factory = { [unowned self] _, _ in
      nextIsFake ? FakeApplet() as any Applet : SlidesFixture()
    }
  }

  func cleanUp() {
    for controller in windows.controllers { controller.window?.close() }

    defaults.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: scratch)
  }

  /// Opens a window whose values sheet and kill grace the test controls.
  func openWindow() throws -> MainWindowController {
    let controller = try windows.open()

    prepare(controller)
    return controller
  }

  func prepare(_ controller: MainWindowController) {
    controller.window?.contentView?.layoutSubtreeIfNeeded()
    controller.execKillGrace = .milliseconds(300)
    controller.execValuesAsker = { [unowned self] keys, _, _ in
      askedKeys.append(keys)
      return values
    }
  }

  func declaration(
    _ mode: String, _ rest: [String] = [], directory: String? = nil, keys: [String] = []
  ) throws -> ExecDeclaration {
    try ExecDeclaration(
      arguments: ExecTestDriver.arguments(mode, type: SlidesFixture.typeID, rest),
      directory: directory, environmentKeys: keys)
  }

  func slides(_ controller: MainWindowController, _ pane: NodeID) -> SlidesFixture? {
    controller.paneArea.applet(for: pane) as? SlidesFixture
  }

  func caller(_ controller: MainWindowController, _ pane: NodeID) -> ScriptCaller {
    ScriptCaller(connection: 1, window: controller.scriptWindowID, pane: pane)
  }

  func command(
    _ controller: MainWindowController, _ pane: NodeID, _ name: String, _ arguments: String = "{}",
    type: String = SlidesFixture.typeID, version: UInt32 = 1,
    stillAllowed: @escaping @MainActor () throws -> Void = {}
  ) async throws -> ScriptValue {
    try await scripting.sendCommand(
      to: .pane(ScriptPaneReference(window: controller.scriptWindowID, pane: pane.rawValue)),
      appletType: type, schemaVersion: version, command: name, arguments: arguments,
      caller: caller(controller, pane), stillAllowed: stillAllowed)
  }
}

@MainActor
final class ExecPaneTests: XCTestCase {
  private func makeFixture() throws -> ExecPaneFixture {
    let fixture = try ExecPaneFixture()
    addTeardownBlock { @MainActor in fixture.cleanUp() }
    return fixture
  }

  private func waitUntil(
    _ what: String, timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line,
    _ condition: () -> Bool
  ) async {
    let deadline = Date().addingTimeInterval(timeout)

    while !condition() {
      guard Date() < deadline else {
        return XCTFail("timed out waiting until \(what)", file: file, line: line)
      }

      try? await Task.sleep(for: .milliseconds(10))
    }
  }

  private func deck(_ titles: [String]) -> String {
    #"{"name":"set-deck","arguments":{"titles":[\#(titles.map { "\"\($0)\"" }.joined(separator: ","))]}}"#
  }

  private func isRunning(_ controller: MainWindowController, _ pane: NodeID) -> Bool {
    controller.execAttachments[pane]?.channel?.isConnected == true
  }

  /// Catches a driver that starts before approval, a request that does not show the exact inputs
  /// it binds, or an approved driver whose stdout does not drive the applet.
  func testRunWaitsForApprovalThenTheDriverDrivesTheApplet() async throws {
    let fixture = try makeFixture()
    let controller = try fixture.openWindow()
    let pane = controller.focusedPane

    try controller.declareExecDriver(fixture.declaration("script", [deck(["A", "B"])]), for: pane)
    controller.runExecDriver(pane)

    let requests = fixture.windows.launchAuthority.requests

    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(requests.first?.launch.arguments.last, deck(["A", "B"]))
    XCTAssertEqual(requests.first?.launch.directory, controller.execEnvironment?.home)
    XCTAssertEqual(requests.first?.launch.environment, [:])
    XCTAssertEqual(requests.first?.target.pane, pane)
    XCTAssertNil(controller.execAttachments[pane]?.channel, "the driver started before approval")
    XCTAssertEqual(fixture.slides(controller, pane)?.titles, [])

    fixture.windows.launchAuthority.decide(try XCTUnwrap(requests.first?.id), .allowOnce)

    await waitUntil("the driver sets the deck") {
      fixture.slides(controller, pane)?.titles == ["A", "B"]
    }

    XCTAssertEqual(controller.control(of: pane).driver, .exec)
    XCTAssertEqual(controller.control(of: pane).access, .disconnected)
  }

  /// Catches Allow once that covers a second launch, and a pane grant that prompts again when only
  /// the arguments change, or that covers a broader program, directory, key set, or pane.
  func testAllowOnceIsOnceAndAGrantCoversOnlyItsScope() async throws {
    let fixture = try makeFixture()
    let controller = try fixture.openWindow()
    let pane = controller.focusedPane
    let authority = fixture.windows.launchAuthority

    try controller.declareExecDriver(fixture.declaration("exit", ["0"]), for: pane)
    controller.runExecDriver(pane)
    authority.decide(try XCTUnwrap(authority.requests.first?.id), .allowOnce)

    await waitUntil("the first run ends") {
      if case .ended? = controller.execAttachments[pane]?.state { return true }
      return false
    }

    controller.runExecDriver(pane)

    XCTAssertEqual(authority.requests.count, 1, "Allow once covered a second launch")

    authority.decide(try XCTUnwrap(authority.requests.first?.id), .allowInPane)

    await waitUntil("the granted run ends") {
      if case .ended? = controller.execAttachments[pane]?.state { return true }
      return false
    }

    try controller.declareExecDriver(fixture.declaration("exit", ["7"]), for: pane)
    controller.runExecDriver(pane)

    XCTAssertTrue(authority.requests.isEmpty, "other arguments in the granted scope asked again")
    XCTAssertNotNil(controller.execAttachments[pane]?.channel)

    await waitUntil("the varied run ends") {
      if case .ended? = controller.execAttachments[pane]?.state { return true }
      return false
    }

    let broader = [
      try fixture.declaration("exit", ["0"], directory: fixture.scratch.path),
      try fixture.declaration("exit", ["0"], keys: ["EXTRA"]),
      try ExecDeclaration(
        arguments: ["/bin/sh", "-c", "exit 0"], directory: nil, environmentKeys: []),
    ]

    fixture.values = ["EXTRA": "x"]

    for declaration in broader {
      try controller.declareExecDriver(declaration, for: pane)
      controller.runExecDriver(pane)

      await waitUntil("\(declaration.arguments.suffix(2)) asks") { !authority.requests.isEmpty }

      XCTAssertEqual(authority.requests.count, 1, "\(declaration) ran without asking")
      XCTAssertNil(controller.execAttachments[pane]?.channel, "\(declaration) ran without asking")

      authority.decide(try XCTUnwrap(authority.requests.first?.id), .deny)
    }

    controller.openPane(.terminalShell, axis: .row)
    let other = controller.focusedPane

    try controller.declareExecDriver(fixture.declaration("exit", ["0"]), for: other)
    controller.runExecDriver(other)

    XCTAssertEqual(authority.requests.count, 1, "the grant covered another pane")
    XCTAssertEqual(authority.requests.first?.target.pane, other)
  }

  /// Catches a remote command that reaches a disconnected pane while its driver commands it, a
  /// remote command that skips the type or version check, and an applet with no commands that
  /// takes one. The driver's commands and the remote ones meet in the same dispatch.
  func testRemoteAndExecShareDispatchAndDisconnectedRefusesOnlyRemote() async throws {
    let fixture = try makeFixture()
    let controller = try fixture.openWindow()
    let pane = controller.focusedPane

    try controller.declareExecDriver(
      fixture.declaration("script", [deck(["A", "B", "C"])]), for: pane)
    controller.runExecDriver(pane)
    fixture.windows.launchAuthority.decide(
      try XCTUnwrap(fixture.windows.launchAuthority.requests.first?.id), .allowOnce)

    await waitUntil("the driver sets the deck") {
      fixture.slides(controller, pane)?.titles.count == 3
    }

    do {
      _ = try await fixture.command(controller, pane, "show-slide", #"{"index":2}"#)
      XCTFail("a disconnected pane took a remote command")
    } catch let error as ScriptCallError {
      XCTAssertEqual(error.kind, .refused)
    }

    XCTAssertEqual(fixture.slides(controller, pane)?.index, 0)

    controller.enableRemoteControl(pane)

    let reply = try await fixture.command(controller, pane, "show-slide", #"{"index":2}"#)

    XCTAssertEqual(reply, .record(["index": .integer(2), "title": .string("C")]))

    for (type, version, name, arguments, kind) in [
      (ChartFixture.typeID, UInt32(1), "status", "{}", ScriptFailureKind.unsupported),
      (SlidesFixture.typeID, 2, "status", "{}", .unsupported),
      (SlidesFixture.typeID, 1, "run", "{}", .badArgument),
      (SlidesFixture.typeID, 1, "show-slide", #"{"index":"1"}"#, .badArgument),
      (SlidesFixture.typeID, 1, "show-slide", "[1]", .badArgument),
      (SlidesFixture.typeID, 1, "show-slide", "not json", .badArgument),
    ] {
      do {
        _ = try await fixture.command(
          controller, pane, name, arguments, type: type, version: version)
        XCTFail("\(type) \(version) \(name) was taken")
      } catch let error as ScriptCallError {
        XCTAssertEqual(error.kind, kind, "\(type) \(version) \(name) \(arguments)")
      }
    }

    XCTAssertEqual(fixture.slides(controller, pane)?.index, 2)

    fixture.nextIsFake = true
    controller.openPane(.terminalShell, axis: .row)
    let fake = controller.focusedPane
    controller.enableRemoteControl(fake)

    do {
      _ = try await fixture.command(controller, fake, "status", type: "fake")
      XCTFail("an applet with no commands took one")
    } catch let error as ScriptCallError {
      XCTAssertEqual(error.kind, .refused)
      XCTAssertTrue(error.text.contains("takes no commands"), error.text)
    }

    XCTAssertThrowsError(try controller.declareExecDriver(fixture.declaration("exit"), for: fake))
  }

  /// Catches a remote command whose grant ends after the checks and before delivery, and still
  /// takes effect.
  func testAuthorityEndingBeforeDeliveryLeavesNoEffect() async throws {
    let fixture = try makeFixture()
    let controller = try fixture.openWindow()
    let pane = controller.focusedPane
    let turns = Turns()

    controller.dispatcher = ControlDispatcher { turns.pending.append($0) }
    controller.enableRemoteControl(pane)

    let deck = Task { @MainActor in
      try await fixture.command(controller, pane, "set-deck", #"{"titles":["A","B"]}"#)
    }

    await waitUntil("the deck waits in the queue") { controller.dispatcher.queuedCount == 1 }
    turns.run()
    _ = try await deck.value

    let pending = Task { @MainActor in
      try await fixture.command(controller, pane, "show-slide", #"{"index":1}"#)
    }

    await waitUntil("the command waits in the queue") { controller.dispatcher.queuedCount == 1 }

    controller.disconnect(pane)
    turns.run()

    do {
      _ = try await pending.value
      XCTFail("a command delivered after disconnect took effect")
    } catch let error as ScriptCallError {
      XCTAssertEqual(error.kind, .refused)
    }

    XCTAssertEqual(fixture.slides(controller, pane)?.index, 0)

    controller.enableRemoteControl(pane)

    let carried = Task { @MainActor in
      try await fixture.command(controller, pane, "show-slide", #"{"index":1}"#)
    }

    await waitUntil("the carried command waits") { controller.dispatcher.queuedCount == 1 }

    controller.disconnect(pane)
    controller.enableRemoteControl(pane)
    turns.run()

    do {
      _ = try await carried.value
      XCTFail("a command queued before a disconnect ran after the pane was enabled again")
    } catch let error as ScriptCallError {
      XCTAssertEqual(error.kind, .refused)
    }

    XCTAssertEqual(fixture.slides(controller, pane)?.index, 0)

    let allowed = Flag(true)
    let revoked = Task { @MainActor in
      try await fixture.command(controller, pane, "show-slide", #"{"index":1}"#) {
        guard allowed.on else { throw ScriptCallError.refused("revoked") }
      }
    }

    await waitUntil("the second command waits") { controller.dispatcher.queuedCount == 1 }

    allowed.on = false
    turns.run()

    do {
      _ = try await revoked.value
      XCTFail("a command delivered after its grant ended took effect")
    } catch let error as ScriptCallError {
      XCTAssertEqual(error.text, "revoked")
    }

    XCTAssertEqual(fixture.slides(controller, pane)?.index, 0)
  }

  /// Catches a driver command that waited in the queue and still runs once the driver no longer
  /// drives the pane: after the driver is replaced by a new declaration, or after the pane closes.
  func testADriverCommandQueuedBeforeItsDriverEndedLeavesNoEffect() async throws {
    let fixture = try makeFixture()
    let controller = try fixture.openWindow()
    let turns = Turns()

    controller.dispatcher = ControlDispatcher { turns.pending.append($0) }
    controller.openPane(.terminalShell, axis: .row)

    for (pane, end) in [(controller.paneIDs[0], "replaced"), (controller.paneIDs[1], "closed")] {
      let applet = try XCTUnwrap(fixture.slides(controller, pane))

      try controller.declareExecDriver(fixture.declaration("script", [deck(["A"])]), for: pane)
      controller.runExecDriver(pane)
      fixture.windows.launchAuthority.decide(
        try XCTUnwrap(fixture.windows.launchAuthority.requests.first?.id), .allowOnce)

      await waitUntil("the driver's set-deck waits in the queue") {
        controller.dispatcher.queuedCount == 1
      }

      if end == "replaced" {
        try controller.declareExecDriver(fixture.declaration("exit"), for: pane)
      } else {
        controller.closePane(pane, appletEnded: false)
      }

      turns.run()

      XCTAssertEqual(applet.titles, [], "a command ran after its driver was \(end)")
    }
  }

  /// Catches a layout that saves an environment value, a restored exec pane that runs anything,
  /// and a Run that does not wait for the values and the approval.
  func testARestoredExecPaneRunsNothingUntilValuesAndApproval() async throws {
    let fixture = try makeFixture()
    let first = try fixture.openWindow()
    let output = fixture.scratch.appendingPathComponent("env")

    try first.declareExecDriver(
      fixture.declaration("env", [output.path], keys: ["SYNTHETIC_TOKEN"]), for: first.focusedPane)
    first.execAttachments[first.focusedPane]?.values = ["SYNTHETIC_TOKEN": "secret-value"]

    let saved = try XCTUnwrap(first.savedWindow())
    let text = String(
      decoding: try LayoutCodec.encode(SavedLayout(windows: [saved])), as: UTF8.self)

    XCTAssertTrue(text.contains("SYNTHETIC_TOKEN"), text)
    XCTAssertFalse(text.contains("secret-value"), "the layout holds an environment value")

    let restored = try fixture.windows.open(
      restoring: RestoredWindow(saved: try LayoutCodec.decode(Data(text.utf8)).windows[0]))
    fixture.prepare(restored)

    let pane = restored.focusedPane
    let authority = fixture.windows.launchAuthority

    XCTAssertEqual(restored.execStatus(of: pane)?.action, "Run")
    XCTAssertTrue(authority.requests.isEmpty)
    XCTAssertNil(restored.execAttachments[pane]?.channel)

    fixture.values = nil
    restored.runExecDriver(pane)

    await waitUntil("the values sheet is answered") { fixture.askedKeys.count == 1 }
    await waitUntil("the cancelled run settles") {
      if case .idle? = restored.execAttachments[pane]?.state { return true }
      return false
    }

    XCTAssertEqual(fixture.askedKeys, [["SYNTHETIC_TOKEN"]])
    XCTAssertTrue(authority.requests.isEmpty, "a run with no values asked for approval")

    fixture.values = ["SYNTHETIC_TOKEN": "fresh"]
    restored.runExecDriver(pane)

    await waitUntil("the run asks for approval") { authority.requests.count == 1 }

    XCTAssertEqual(authority.requests.first?.launch.environment, ["SYNTHETIC_TOKEN": "fresh"])
    XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "it ran before approval")

    authority.decide(try XCTUnwrap(authority.requests.first?.id), .allowOnce)

    await waitUntil("the driver writes its environment") {
      (try? String(contentsOf: output, encoding: .utf8))?.contains("SYNTHETIC_TOKEN=fresh") == true
    }
  }

  /// Catches a pane close that leaves the driver's authority in place, or that waits for the child.
  func testClosingThePaneEndsAuthorityAtOnceAndTheChildAfter() async throws {
    let fixture = try makeFixture()
    let controller = try fixture.openWindow()

    controller.openPane(.terminalShell, axis: .row)
    let pane = controller.focusedPane

    try controller.declareExecDriver(fixture.declaration("ignore-term"), for: pane)
    controller.runExecDriver(pane)
    fixture.windows.launchAuthority.decide(
      try XCTUnwrap(fixture.windows.launchAuthority.requests.first?.id), .allowOnce)

    await waitUntil("the driver connects") { isRunning(controller, pane) }

    let channel = try XCTUnwrap(controller.execAttachments[pane]?.channel)
    let pid = try XCTUnwrap(channel.pid)
    let started = Date()

    controller.closePane(pane, appletEnded: false)

    XCTAssertLessThan(Date().timeIntervalSince(started), 0.2, "the close waited for the child")
    XCTAssertFalse(channel.isConnected)
    XCTAssertNil(controller.execAttachments[pane])

    await waitUntil("the child is gone") { kill(pid, 0) != 0 }
  }

  /// Catches a command that ran but whose reply a script cannot hold, reported as an ordinary
  /// failure. The script must learn that the command took effect.
  func testAReplyAScriptCannotHoldSaysTheCommandRan() {
    var deep = JSONValue.string("bottom")

    for _ in 0...ScriptValue.maxDepth { deep = .array([deep]) }

    let wide = JSONValue.object(
      Dictionary(uniqueKeysWithValues: (0...ScriptValue.maxRecordFields).map { ("k\($0)", .null) }))

    for reply in [deep, wide] {
      XCTAssertThrowsError(try WindowScripting.scriptValue(reply, depth: 0)) { error in
        XCTAssertEqual((error as? ScriptCallError)?.kind, .replyLost)
        XCTAssertTrue(
          (error as? ScriptCallError)?.text.contains("the command ran") == true, "\(error)")
      }
    }
  }

  /// Catches a quit that leaves a driver running. The driver ignores SIGTERM and its group is its
  /// own, so only a SIGKILL that goes out before the app exits ends it. The kill grace is far
  /// longer than the test, so the delayed SIGKILL of an ordinary close cannot be what ends it.
  func testQuitEndsEveryDriverBeforeTheAppExits() async throws {
    let fixture = try makeFixture()
    let controller = try fixture.openWindow()
    let pane = controller.focusedPane

    controller.execKillGrace = .seconds(60)
    try controller.declareExecDriver(fixture.declaration("ignore-term"), for: pane)
    controller.runExecDriver(pane)
    fixture.windows.launchAuthority.decide(
      try XCTUnwrap(fixture.windows.launchAuthority.requests.first?.id), .allowOnce)

    await waitUntil("the driver connects") { isRunning(controller, pane) }

    let pid = try XCTUnwrap(controller.execAttachments[pane]?.channel?.pid)
    let started = Date()

    fixture.windows.endDriversForQuit()

    XCTAssertLessThan(Date().timeIntervalSince(started), 2, "the quit waited without a bound")

    await waitUntil("the driver is gone", timeout: 3) { kill(pid, 0) != 0 }

    if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
  }

  /// Catches a stalled driver that holds the main thread: while it neither reads nor writes, and
  /// the applet floods it with events, main-thread work still runs within a turn.
  func testAStalledDriverNeverHoldsTheMainThread() async throws {
    let fixture = try makeFixture()
    let controller = try fixture.openWindow()
    let pane = controller.focusedPane

    try controller.declareExecDriver(fixture.declaration("stall"), for: pane)
    controller.runExecDriver(pane)
    fixture.windows.launchAuthority.decide(
      try XCTUnwrap(fixture.windows.launchAuthority.requests.first?.id), .allowOnce)

    await waitUntil("the driver connects") { isRunning(controller, pane) }

    let applet = try XCTUnwrap(fixture.slides(controller, pane))
    let started = Date()

    for _ in 0..<20_000 { applet.button.performClick(nil) }

    let turned = Flag(false)
    DispatchQueue.main.async { MainActor.assumeIsolated { turned.on = true } }

    await waitUntil("the main thread takes another turn", timeout: 2) { turned.on }

    XCTAssertLessThan(Date().timeIntervalSince(started), 5)
  }
}

@MainActor
private final class Flag {
  var on: Bool

  init(_ on: Bool) { self.on = on }
}

/// The dispatcher's turns, held so a test runs them when it chooses.
@MainActor
private final class Turns {
  var pending: [@MainActor () -> Void] = []

  func run() {
    let bodies = pending
    pending = []
    for body in bodies { body() }
  }
}
