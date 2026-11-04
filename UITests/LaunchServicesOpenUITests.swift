import AppKit
import XCTest

/// Sends the running app an open-documents event the way another program does. The runner is not
/// an Apple opener, so the event must be refused with a message and open nothing. An accepted open
/// needs Finder as the sender, which no test can be, so the unit tests cover it and the milestone
/// leaves a hand check for Finder and the Dock.
@MainActor
final class LaunchServicesOpenUITests: UnitermUITestCase {
  /// Catches an open from a program that is not Finder or the Dock opening a pane, or going
  /// unanswered. The app is the one under test, found by its bundle identifier among the running
  /// applications, so Launch Services sends the event to this instance.
  func testAnOpenFromAnotherProgramIsRefusedWithAMessageAndOpensNoPane() throws {
    let app = launchApp()
    let window = app.windows["main-window"]
    _ = waitForTerminal(in: app)

    let running = try XCTUnwrap(
      NSRunningApplication.runningApplications(withBundleIdentifier: "dev.uniterm.app").first)
    let appURL = try XCTUnwrap(running.bundleURL)

    let folder = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("uniterm-open-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }

    let opened = expectation(description: "the open was handed to Launch Services")

    NSWorkspace.shared.open(
      [folder], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration()
    ) { _, error in
      XCTAssertNil(error)
      opened.fulfill()
    }

    wait(for: [opened], timeout: 20)

    let message = window.staticTexts["status-message"]
    XCTAssertTrue(
      waitFor(message, timeout: 15) { $0.contains("did not open the files sent by") },
      "the refusal never reached the status bar")

    XCTAssertEqual(window.textViews.matching(identifier: "terminal").count, 1)
  }
}
