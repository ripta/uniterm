import XCTest

/// The base class of every UI test. It launches the app in an isolated environment.
///
/// The app reads a throwaway plist for its preferences and writes its terminal config and its saved
/// layout to scratch folders, so no test touches the developer's settings or layout. The layout
/// folder lasts for the whole test, so a test can quit the app and launch it again over the same
/// saved layout.
///
/// The shell reads a fixture folder through `ZDOTDIR` and never the developer's dotfiles. Those may
/// prompt for an ssh passphrase or run anything else. Ghostty's zsh integration restores `ZDOTDIR`
/// for the startup files, so the integration stays on. The production app still starts the user's
/// real login shell.
@MainActor
class UnitermUITestCase: XCTestCase {
  private(set) var scratch = ""
  private var launched: [XCUIApplication] = []

  override func setUpWithError() throws {
    continueAfterFailure = false
    scratch = NSTemporaryDirectory() + "uniterm-ui-\(UUID().uuidString)"

    try FileManager.default.createDirectory(
      atPath: scratch + "-shell", withIntermediateDirectories: true)
    try Data().write(to: URL(fileURLWithPath: scratch + "-shell/.zshrc"))
  }

  /// A leftover instance would be logged at the next launch, so every test ends its app.
  override func tearDownWithError() throws {
    for app in launched where app.state != .notRunning {
      app.terminate()
    }

    launched = []
    try? FileManager.default.removeItem(atPath: scratch + "-shell")
    try? FileManager.default.removeItem(atPath: scratch + "-terminal")
    try? FileManager.default.removeItem(atPath: scratch + "-layout")
  }

  /// The folder the app saves its layout in during this test.
  var layoutDirectory: URL {
    URL(fileURLWithPath: scratch + "-layout", isDirectory: true)
  }

  /// Writes a layout file before the app launches.
  func plantLayout(_ json: String) throws {
    try FileManager.default.createDirectory(at: layoutDirectory, withIntermediateDirectories: true)
    try Data(json.utf8).write(to: layoutDirectory.appendingPathComponent("layout.json"))
  }

  /// Launches the app. `settings` are written into the app's isolated defaults first, as
  /// `defaults write` would, so a test starts with a setting such as `paletteMode` already chosen.
  func launchApp(
    environment: [String: String] = [:], arguments: [String] = [], settings: [String: String] = [:]
  ) -> XCUIApplication {
    if !settings.isEmpty, let defaults = UserDefaults(suiteName: scratch) {
      for (key, value) in settings {
        defaults.set(value, forKey: key)
      }

      defaults.synchronize()
    }

    let app = XCUIApplication()
    for (key, value) in environment {
      app.launchEnvironment[key] = value
    }

    app.launchArguments += arguments

    app.launchEnvironment["UNITERM_DEFAULTS_PATH"] = scratch
    app.launchEnvironment["UNITERM_TERMINAL_DIR"] = scratch + "-terminal"
    app.launchEnvironment["UNITERM_LAYOUT_DIR"] = scratch + "-layout"
    app.launchEnvironment["UNITERM_BROWSER_DIR"] = scratch + "-browser"
    app.launchEnvironment["SHELL"] = "/bin/zsh"
    app.launchEnvironment["ZDOTDIR"] = scratch + "-shell"
    app.launchEnvironment["SSH_AUTH_SOCK"] = ""
    app.launchEnvironment["UNITERM_PLACE_NAMES"] = "off"
    app.launch()
    app.activate()
    launched.append(app)
    return app
  }

  // MARK: Waiting

  /// The nth main window in the order opened, counting from 1. The first is `main-window`. A
  /// number is never reused, so a window opened after a close takes the next one.
  func mainWindow(_ number: Int = 1, in app: XCUIApplication) -> XCUIElement {
    app.windows[number == 1 ? "main-window" : "main-window-\(number)"]
  }

  /// Waits for the window's first terminal to show a prompt. Windows other than the first need
  /// their own number.
  func waitForTerminal(in app: XCUIApplication, window number: Int = 1) -> XCUIElement {
    let terminal = mainWindow(number, in: app).textViews["terminal"]
    XCTAssertTrue(terminal.waitForExistence(timeout: 15))

    // Keys typed before the shell reads its terminal can be lost. The fixture's zsh prompt ends in
    // "% ", so wait for it.
    XCTAssertTrue(
      waitFor(terminal, timeout: 40) { $0.contains("% ") }, "the shell never showed a prompt")
    return terminal
  }

  func waitFor(
    _ element: XCUIElement, timeout: TimeInterval, _ condition: @escaping (String) -> Bool
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)

    while Date() < deadline {
      if let value = element.value as? String, condition(value) {
        return true
      }

      Thread.sleep(forTimeInterval: 0.25)
    }

    return false
  }

  func firstMatch(_ pattern: String, in text: String) -> String? {
    guard let expression = try? NSRegularExpression(pattern: pattern),
      let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
      match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text)
    else { return nil }

    return String(text[range])
  }

  func waitUntilGone(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
    let gone = NSPredicate(format: "exists == false")
    return XCTWaiter().wait(
      for: [XCTNSPredicateExpectation(predicate: gone, object: element)], timeout: timeout)
      == .completed
  }

  /// Opens Settings, picks a status bar position, and closes Settings so a main window is key
  /// again.
  func chooseStatusBarPosition(_ title: String, in app: XCUIApplication) {
    app.typeKey(",", modifierFlags: .command)
    let settings = app.windows["settings-window"]
    XCTAssertTrue(settings.waitForExistence(timeout: 5))

    let control = settings.radioGroups["status-bar-position-control"]
    XCTAssertTrue(control.waitForExistence(timeout: 5))
    control.radioButtons[title].click()

    app.typeKey("w", modifierFlags: .command)
    XCTAssertTrue(waitUntilGone(settings, timeout: 5))
  }

  func waitForNoSheet(in window: XCUIElement, timeout: TimeInterval = 5) -> Bool {
    let gone = NSPredicate(format: "exists == false")
    let sheet = window.sheets.firstMatch
    return XCTWaiter().wait(
      for: [XCTNSPredicateExpectation(predicate: gone, object: sheet)], timeout: timeout)
      == .completed
  }

  // MARK: Launcher

  /// The launcher in a window. It is the whole content of a new pane until an applet is chosen.
  func launcher(in window: XCUIElement) -> XCUIElement {
    window.descendants(matching: .any)["launcher"]
  }

  /// Presses a split key, waits for the launcher, then accepts its default, a terminal in shell
  /// mode.
  func openPane(
    in app: XCUIApplication, window number: Int = 1, keys: String,
    modifiers: XCUIElement.KeyModifierFlags
  ) {
    let window = mainWindow(number, in: app)

    app.typeKey(keys, modifierFlags: modifiers)
    XCTAssertTrue(launcher(in: window).waitForExistence(timeout: 5), "the launcher never opened")

    app.typeKey(.return, modifierFlags: [])
    XCTAssertTrue(waitUntilGone(launcher(in: window), timeout: 10), "Return left the launcher")
  }
}
