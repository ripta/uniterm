import AppKit
import AppletKit
import PaneModel
import Preferences
import StatusKit
import XCTest

@testable import WindowKit

extension MainWindowController {
  /// Opens `choice` beside the focused pane, as the tests do when no particular pane matters.
  @discardableResult
  func openPane(_ choice: AppletChoice, axis: Axis) -> NodeID? {
    openPane(choice, axis: axis, from: focusedPane)
  }

  @discardableResult
  func openLauncher(axis: Axis) -> NodeID? {
    openLauncher(axis: axis, from: focusedPane)
  }
}

final class TestClock: StatusClock, @unchecked Sendable {
  var now: TimeInterval = 0
}

/// Holds the wakeups that a status center asks for, so a test fires them by hand.
@MainActor
final class TestScheduler {
  private(set) var actions: [@MainActor () -> Void] = []

  func schedule(_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void)
    -> @MainActor ()
    -> Void
  {
    actions.append(action)
    return {}
  }

  func fireLast() {
    actions.last?()
  }
}

/// Holds the wakeups a timer asks for, so a test fires them by hand. A cancelled wake is gone, as
/// with a real timer.
@MainActor
final class WakeScheduler {
  private var counter = 0
  private(set) var pending: [Int: (delay: TimeInterval, action: @MainActor () -> Void)] = [:]

  func schedule(_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void)
    -> @MainActor ()
    -> Void
  {
    counter += 1
    let id = counter
    pending[id] = (delay, action)

    return { [weak self] in self?.pending[id] = nil }
  }

  /// Runs the one pending wake, if there is one.
  func fire() {
    guard let id = pending.keys.min(), let entry = pending.removeValue(forKey: id) else { return }

    entry.action()
  }
}

@MainActor
final class AppletLog {
  var made: [FakeApplet] = []

  /// The directory each applet was asked to start in, oldest first.
  var requested: [String?] = []
}

/// One window over an isolated defaults suite, a manual clock, and fake applets. The first applet
/// is the first pane's.
@MainActor
final class WindowFixture {
  let suite = "uniterm-window-test-\(UUID().uuidString)"
  let defaults: UserDefaults
  let store: SettingsStore
  let clock = TestClock()
  let scheduler = TestScheduler()
  let center: StatusCenter
  let log: AppletLog
  let controller: MainWindowController

  /// The fake applet's declaration, so the palette names its tabs the way it names a real applet's.
  static let fakeType = AppletTypeDeclaration(
    typeID: "fake", displayName: "Fake", symbolName: "terminal", opens: [])

  init(
    storedPosition: String? = nil, stored: [String: String] = [:],
    commands: CommandRegistry = .testing(),
    appletTypes: [AppletTypeDeclaration] = [WindowFixture.fakeType]
  ) throws {
    let defaults = UserDefaults(suiteName: suite)!
    if let storedPosition {
      defaults.set(storedPosition, forKey: "statusBarPosition")
    }

    for (key, value) in stored {
      defaults.set(value, forKey: key)
    }

    let store = SettingsStore(defaults: defaults)
    let clock = clock
    let scheduler = scheduler
    let center = StatusCenter(clock: clock, scheduler: scheduler.schedule)
    let log = AppletLog()

    self.defaults = defaults
    self.store = store
    self.center = center
    self.log = log

    controller = try MainWindowController(
      appearance: AppearanceController(store: store), settings: store, statusCenter: center,
      commands: commands, appletTypes: appletTypes
    ) { _, _ in
      let applet = FakeApplet()
      log.made.append(applet)
      return applet
    }

    controller.windowShowsContentOverride = { true }
    controller.window?.contentView?.layoutSubtreeIfNeeded()
  }

  func cleanUp() {
    defaults.removePersistentDomain(forName: suite)
  }

  var bar: StatusBarView { controller.contentController.statusBar }
  var paneArea: PaneAreaView { controller.paneArea }
  var chrome: NSView { controller.contentController.view }

  func layout() {
    chrome.layoutSubtreeIfNeeded()
  }

  /// The text of the message area.
  var messageText: String? {
    bar.segments.first { $0.id == .message }?.text
  }
}

/// Polls until a condition holds. A store reports a change on a later turn of the main actor.
@MainActor
func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
  let deadline = Date().addingTimeInterval(timeout)

  while Date() < deadline {
    if condition() { return true }

    try? await Task.sleep(for: .milliseconds(20))
  }

  return condition()
}

/// Runs `defaults` as a separate process, as a user's `defaults write` does.
func runDefaults(_ arguments: [String]) throws -> String {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
  process.arguments = arguments

  let pipe = Pipe()
  process.standardOutput = pipe
  try process.run()

  let output = pipe.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  XCTAssertEqual(process.terminationStatus, 0, "defaults \(arguments) failed")

  return String(decoding: output, as: UTF8.self)
}

/// A menu built from a window's registry, not installed, with the window as its key window.
@MainActor
struct MenuHarness {
  let menu: CommandMenu

  init(_ controller: MainWindowController) {
    menu = CommandMenu(registry: controller.commands, activeController: { controller })
    menu.keyController = { controller }
  }

  func item(_ id: CommandID) -> CommandMenuItem? {
    func find(in menu: NSMenu) -> CommandMenuItem? {
      for item in menu.items {
        if let found = item as? CommandMenuItem, found.commandID == id { return found }

        if let submenu = item.submenu, let found = find(in: submenu) { return found }
      }

      return nil
    }

    return find(in: menu.menu)
  }

  func validate(_ id: CommandID) -> Bool {
    item(id).map { menu.validateMenuItem($0) } ?? false
  }
}
