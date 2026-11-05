import AppKit
import AppletKit
import StatusKit
import TableData
import XCTest

@testable import DataViewerApplet

/// Collects what an applet tells its pane.
@MainActor
final class RecordingHost: AppletHost {
  var posts: [(level: StatusLevel, text: String)] = []
  var changes = 0
  var tabChanges = 0

  func applet(_ applet: any Applet, post level: StatusLevel, text: String) {
    posts.append((level, text))
  }

  func appletDidExit(_ applet: any Applet) {}

  func appletDidChange(_ applet: any Applet) { changes += 1 }

  func appletTabsDidChange(_ applet: any Applet) { tabChanges += 1 }

  func applet(_ applet: any Applet, confirm request: AppletConfirmation) async -> Bool { false }

  func issueCloseStamp() -> UInt64 { 0 }
}

final class Scratch {
  let url: URL

  init(_ test: XCTestCase) throws {
    url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("uniterm-viewer-\(UUID().uuidString)", isDirectory: true)
      .resolvingSymlinksInPath()

    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

    let folder = url
    test.addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
  }

  @discardableResult
  func write(_ name: String, _ text: String) throws -> URL {
    let file = url.appendingPathComponent(name)
    try Data(text.utf8).write(to: file)
    return file
  }
}

@MainActor
extension XCTestCase {
  func eventually(timeout: Double = 10, _ condition: @escaping @MainActor () -> Bool) async -> Bool
  {
    let deadline = Date().addingTimeInterval(timeout)

    while Date() < deadline {
      if condition() { return true }

      try? await Task.sleep(for: .milliseconds(10))
    }

    return condition()
  }
}

func makeBudget() -> TableBudget {
  TableBudget(limit: 1 << 30, floor: 1 << 20)
}
