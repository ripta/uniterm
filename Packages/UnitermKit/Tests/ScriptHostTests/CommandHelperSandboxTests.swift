import Darwin
import Foundation
import XCTest

@testable import ScriptHost

/// Checks the `uniterm` command built into the app. `make test-helper-sandbox` names it with
/// `UNITERM_COMMAND_HELPER`. Without the variable the test skips, since a package build has no
/// bundle command.
///
/// The app accepts a controller run only from the bundle's own command, matched by its code hash.
/// That match means nothing if dyld can load other code into the command first, so the command must
/// carry the hardened runtime, and an injected library must not load.
final class CommandHelperSandboxTests: XCTestCase {
  private var shippedCommand: URL? {
    ProcessInfo.processInfo.environment["UNITERM_COMMAND_HELPER"].flatMap {
      $0.isEmpty ? nil : URL(fileURLWithPath: $0)
    }
  }

  /// Catches a shipped command signed without the hardened runtime, or one into which
  /// `DYLD_INSERT_LIBRARIES` still loads a library. The library is the system's GuardMalloc, which
  /// prints a banner once it is loaded.
  func testTheShippedCommandCarriesTheHardenedRuntimeAndRefusesInjection() throws {
    guard let command = shippedCommand else {
      throw XCTSkip(
        "UNITERM_COMMAND_HELPER names no shipped command. Run make test-helper-sandbox.")
    }

    let identity = try XCTUnwrap(CodeIdentity.ofFile(at: command), "the command is not signed")

    XCTAssertTrue(identity.hasHardenedRuntime, "the shipped command has no hardened runtime")
    XCTAssertFalse(identity.allowsLoaderVariables, "the shipped command lets dyld variables in")

    let process = Process()
    let errors = Pipe()

    process.executableURL = command
    process.arguments = ["--help"]
    process.environment = ["DYLD_INSERT_LIBRARIES": "/usr/lib/libgmalloc.dylib"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = errors
    try process.run()
    process.waitUntilExit()

    let text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

    XCTAssertFalse(text.contains("GuardMalloc"), text)
  }
}
