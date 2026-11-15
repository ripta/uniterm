import AppKit
import Preferences
import TerminalSurface
import Theme
import WindowKit
import XCTest

@testable import TerminalApplet

@MainActor
private final class RecordingEngine: TerminalEngine {
  var palettes: [ThemePalette] = []
  var failure: (any Error)?
  var anySessionRunningSomething = false

  func makeSession(launch: TerminalLaunch, clipboardPolicy: TerminalClipboardPolicy) throws
    -> any TerminalSession
  {
    throw CocoaError(.featureUnsupported)
  }

  func apply(palette: ThemePalette) throws {
    palettes.append(palette)
    if let failure { throw failure }
  }
}

@MainActor
final class TerminalPaletteSyncTests: XCTestCase {
  private func settle(_ condition: () -> Bool) async {
    for _ in 0..<200 where !condition() {
      try? await Task.sleep(for: .milliseconds(10))
    }
  }

  /// Catches an appearance change that never reaches the terminal engine. The real appearance
  /// controller and settings store drive the sync, as the app wires them. Flipping the setting
  /// calls `apply(palette:)` with the Mocha and then the Latte palette.
  func testAppearanceSettingDrivesTheEngine() async {
    let store = SettingsStore(defaults: UserDefaults(suiteName: "uniterm-sync-\(UUID())")!)
    let appearance = AppearanceController(store: store)
    let engine = RecordingEngine()
    let sync = TerminalPaletteSync(engine: engine) { _ in XCTFail("the engine did not fail") }
    _ = appearance.addObserver { sync.apply($0) }

    XCTAssertEqual(engine.palettes.last?.flavor, .latte)

    store.set(.dark, for: .appearance)
    await settle { engine.palettes.last?.flavor == .mocha }
    XCTAssertEqual(engine.palettes.last?.flavor, .mocha)

    store.set(.light, for: .appearance)
    await settle { engine.palettes.last?.flavor == .latte && engine.palettes.count >= 3 }
    XCTAssertEqual(engine.palettes.last?.flavor, .latte)
    XCTAssertEqual(engine.palettes.map(\.flavor), [.latte, .mocha, .latte])
  }

  /// A palette that did not apply is reported, not swallowed.
  func testFailureGoesToTheCaller() {
    let engine = RecordingEngine()
    engine.failure = CocoaError(.fileWriteNoPermission)
    var reported: [any Error] = []
    let sync = TerminalPaletteSync(engine: engine) { reported.append($0) }

    sync.apply(.mocha)

    XCTAssertEqual(reported.count, 1)
  }
}
