import Foundation
import XCTest

/// The structural guarantee behind "scripts cannot approve their own requests or activate Run":
/// no code a script or a driver reaches holds a path to the launch authority or to Run.
///
/// It reads the package's sources, so a change that wires a script call, a driver command, or the
/// window side of the host API to either one fails here, whatever the call is named. It cannot
/// prove the panel's buttons are pressed only by a person. That is the panel's own job.
final class ExecLaunchIsolationTests: XCTestCase {
  private static let sources = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Sources", isDirectory: true)

  private func files(in module: String) throws -> [URL] {
    let folder = Self.sources.appendingPathComponent(module, isDirectory: true)

    return try FileManager.default.contentsOfDirectory(
      at: folder, includingPropertiesForKeys: nil
    ).filter { ["swift", "c", "h"].contains($0.pathExtension) }
  }

  /// Catches a script or driver path that names the launch authority, Run, or a declaration.
  func testNoScriptOrDriverPathReachesLaunchAuthorityOrRun() throws {
    let reachable =
      try ["ScriptHost", "ScriptWire", "ScriptRuntime", "ScriptHelper", "CJanet", "ExecDriver"]
      .flatMap(files)
      + [Self.sources.appendingPathComponent("WindowKit/WindowScripting.swift")]

    let forbidden = [
      "ExecLaunchAuthority", "launchAuthority", "runExecDriver", "declareExecDriver",
      "execAttachments",
    ]

    XCTAssertGreaterThan(reachable.count, 20, "the sources were not found")

    for file in reachable where file.lastPathComponent != "janet.c" {
      let text = try String(contentsOf: file, encoding: .utf8)

      for name in forbidden {
        XCTAssertFalse(text.contains(name), "\(file.lastPathComponent) names \(name)")
      }
    }
  }

  /// Catches a second caller of Run or of a launch decision. Run starts only from the pane's own
  /// strip and a values sheet the user answered, and a decision comes only from the panel.
  func testRunAndDecisionsHaveOnlyTheirLocalCallers() throws {
    var runCallers: Set<String> = []
    var decideCallers: Set<String> = []

    for file in try files(in: "WindowKit") {
      let text = try String(contentsOf: file, encoding: .utf8)

      if text.contains("runExecDriver(pane)") { runCallers.insert(file.lastPathComponent) }

      if text.contains("launches.decide(") || text.contains("launchAuthority.decide(") {
        decideCallers.insert(file.lastPathComponent)
      }
    }

    XCTAssertEqual(runCallers, ["MainWindowController.swift", "MainWindowController+Exec.swift"])
    XCTAssertEqual(decideCallers, ["PendingRequestsWindowController.swift"])
  }
}
