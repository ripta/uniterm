import AppKit
import Foundation
internal import GhosttyKit
import OSLog
import Theme

public enum TerminalEngineError: Error {
  case initFailed(code: Int32)
  case invalidConfig([String])
  case appCreateFailed
  case surfaceCreateFailed
}

/// Runs libghostty's one-time global setup. It passes a fixed argv, so command-line flags of
/// uniterm never reach libghostty.
private enum GhosttyGlobal {
  static let initResult: Int32 = {
    var program = Array("uniterm".utf8CString)

    return program.withUnsafeMutableBufferPointer { buffer in
      var argv: [UnsafeMutablePointer<CChar>?] = [buffer.baseAddress, nil]
      return argv.withUnsafeMutableBufferPointer { ghostty_init(1, $0.baseAddress) }
    }
  }()
}

/// The libghostty implementation of the terminal engine.
///
/// uniterm builds the libghostty config from its own theme tokens and loads no other file. The
/// config goes in a per-instance file because libghostty reads config only from a file path.
@MainActor
public final class GhosttyTerminalEngine: TerminalEngine {
  private let logger = Logger(subsystem: "dev.uniterm.app", category: "terminal")
  private let store: TerminalConfigStore
  private let wakeupTarget = WakeupTarget()
  private var app: ghostty_app_t?
  private var config: ghostty_config_t?
  private var palette: ThemePalette
  private let sessions = NSHashTable<GhosttySurfaceView>.weakObjects()
  private var notificationTokens: [any NSObjectProtocol] = []
  private let helperDirectory: URL

  /// The search path a shell gets when uniterm itself was started with none.
  static let defaultPath = "/usr/bin:/bin:/usr/sbin:/sbin"

  /// - Parameters:
  ///   - resourcesDirectory: The `ghostty` directory that holds the shell-integration scripts, next
  ///     to the `terminfo` directory. The engine always exports it as `GHOSTTY_RESOURCES_DIR`, so a
  ///     value inherited from another Ghostty never decides which resources the shells use.
  ///   - helperDirectory: The directory that holds uniterm's `ghostty` helper. Ghostty's shell
  ///     integration finds it through `GHOSTTY_BIN_DIR`. See `launchEnvironment`.
  public init(
    configStore: TerminalConfigStore, resourcesDirectory: URL, helperDirectory: URL,
    palette: ThemePalette
  ) throws {
    self.store = configStore
    self.palette = palette
    self.helperDirectory = helperDirectory

    setenv("GHOSTTY_RESOURCES_DIR", resourcesDirectory.path, 1)

    let initResult = GhosttyGlobal.initResult
    guard initResult == 0 else {
      throw TerminalEngineError.initFailed(code: initResult)
    }

    store.removeStaleFiles()
    let config = try makeConfig(for: palette)
    self.config = config

    wakeupTarget.engine = self

    var runtime = GhosttyCallbacks.runtimeConfig(
      userdata: Unmanaged.passRetained(wakeupTarget).toOpaque())

    guard let app = ghostty_app_new(&runtime, config) else {
      Unmanaged.passUnretained(wakeupTarget).release()
      ghostty_config_free(config)
      self.config = nil
      throw TerminalEngineError.appCreateFailed
    }

    self.app = app
    ghostty_app_set_focus(app, NSApp?.isActive ?? true)
    observeApplication()
  }

  isolated deinit {
    for token in notificationTokens {
      NotificationCenter.default.removeObserver(token)
    }

    if let app {
      ghostty_app_free(app)
      Unmanaged.passUnretained(wakeupTarget).release()
    }

    if let config {
      ghostty_config_free(config)
    }

    store.removeOwnFile()
  }

  /// Deletes this instance's generated config. The app calls it as it quits.
  public func removeConfigFile() {
    store.removeOwnFile()
  }

  public var anySessionRunningSomething: Bool {
    sessions.allObjects.contains { !$0.hasExited && $0.isRunningSomething }
  }

  public func makeSession(launch: TerminalLaunch) throws -> any TerminalSession {
    guard let app else { throw TerminalEngineError.appCreateFailed }

    var launch = launch
    launch.environment = Self.launchEnvironment(
      launch.environment, helperDirectory: helperDirectory,
      inheritedPath: ProcessInfo.processInfo.environment["PATH"])

    let view = try GhosttySurfaceView(app: app, launch: launch)
    sessions.add(view)
    return view
  }

  /// libghostty points `GHOSTTY_BIN_DIR` at the host executable's directory and appends that
  /// directory to `PATH`, assuming the host is Ghostty itself. uniterm sets both instead, so every
  /// shell sees values uniterm chose. A launch's own value still wins.
  ///
  /// `GHOSTTY_BIN_DIR` names uniterm's helper, which stands in for `ghostty +ssh`. `PATH` is the
  /// one uniterm inherited, without uniterm's own executable directory.
  static func launchEnvironment(
    _ environment: [String: String], helperDirectory: URL, inheritedPath: String?
  ) -> [String: String] {
    let chosen = [
      "GHOSTTY_BIN_DIR": helperDirectory.path,
      "PATH": inheritedPath ?? defaultPath,
    ]

    return chosen.merging(environment) { $1 }
  }

  public func apply(palette: ThemePalette) throws {
    guard let app, palette != self.palette else { return }

    let updated = try makeConfig(for: palette)
    ghostty_app_update_config(app, updated)

    if let previous = config {
      ghostty_config_free(previous)
    }

    config = updated
    self.palette = palette
  }

  func tick() {
    guard let app else { return }

    ghostty_app_tick(app)
  }

  private func makeConfig(for palette: ThemePalette) throws -> ghostty_config_t {
    let file = try store.write(try TerminalConfig.make(palette: palette).render())

    guard let config = ghostty_config_new() else {
      throw TerminalEngineError.appCreateFailed
    }

    ghostty_config_load_file(config, file.path)
    ghostty_config_finalize(config)

    let count = ghostty_config_diagnostics_count(config)
    if count > 0 {
      var messages: [String] = []
      for index in 0..<count {
        if let message = ghostty_config_get_diagnostic(config, index).message {
          messages.append(String(cString: message))
        }
      }

      ghostty_config_free(config)
      throw TerminalEngineError.invalidConfig(messages)
    }

    return config
  }

  private func observeApplication() {
    let center = NotificationCenter.default

    let active = center.addObserver(
      forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.setApplicationFocus(true) }
    }

    let inactive = center.addObserver(
      forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.setApplicationFocus(false) }
    }

    let keyboard = center.addObserver(
      forName: NSTextInputContext.keyboardSelectionDidChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        if let app = self?.app {
          ghostty_app_keyboard_changed(app)
        }
      }
    }

    notificationTokens = [active, inactive, keyboard]
  }

  private func setApplicationFocus(_ focused: Bool) {
    guard let app else { return }

    ghostty_app_set_focus(app, focused)
  }
}
