import Foundation
import ImageTestSupport
import ImageViewerModel
import ImageWire
import XCTest

@testable import ImageViewerApplet

/// Settings that point a client at the unsandboxed helper SwiftPM builds beside the tests. The
/// times are short so a limit is reached in a fraction of a second. The helper is a real process,
/// so a wait for its events polls, since nothing else says when another process has answered.
@MainActor
enum Harness {
  static func settings(
    location: HelperLocation? = nil, timeBound: Duration = .seconds(10),
    footprintCap: Int = ImageHelperPolicy.perHelperCap
  ) -> HelperSettings {
    HelperSettings(
      location: location ?? HelperLocation(url: ImageFixtures.packageHelper()),
      timeBound: timeBound, probeInterval: .milliseconds(40), pongGrace: .milliseconds(500),
      footprintCap: footprintCap)
  }

  /// Polls until `condition` holds or `seconds` pass. Returns whether it held.
  static func eventually(
    seconds: Double = 20, _ condition: @MainActor () -> Bool
  ) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)

    while ContinuousClock.now < deadline {
      if condition() { return true }

      try? await Task.sleep(for: .milliseconds(10))
    }

    return condition()
  }

  /// A script that stands in for a helper. It writes `frame` to the socket and then waits.
  static func scriptHelper(writing octal: String) throws -> HelperLocation {
    let path = NSTemporaryDirectory() + "uniterm-fake-helper-\(UUID().uuidString)"
    let script = "#!/bin/sh\nprintf '\(octal)' >&3\nexec /bin/sleep 30\n"

    try script.write(toFile: path, atomically: true, encoding: .utf8)
    chmod(path, 0o755)

    return HelperLocation(url: URL(fileURLWithPath: path))
  }
}

/// Collects a client's events in order.
@MainActor
final class EventLog {
  private(set) var events: [HelperEvent] = []

  init(_ client: ImageHelperClient) {
    client.onEvent = { [weak self] in self?.events.append($0) }
  }

  func first<T>(_ match: (HelperEvent) -> T?) -> T? {
    for event in events {
      if let found = match(event) { return found }
    }

    return nil
  }

  var ended: HelperEnd? {
    first { if case .ended(let end, _) = $0 { return end } else { return nil } }
  }

  var opened: SourceInfo? {
    first { if case .opened(let info) = $0 { return info } else { return nil } }
  }

  var images: [ImageHeader] {
    events.compactMap {
      if case .image(_, let header, _) = $0 { return header } else { return nil }
    }
  }
}

/// A scratch folder and a file opened from it, for a test that talks to a client directly.
@MainActor
func openedFile(_ data: Data, named name: String = "a.png", in folder: URL) throws
  -> OpenedImageFile
{
  let url = try ImageFixtures.write(data, named: name, in: folder)

  guard case .success(.file(let file)) = SourceOpener.open(path: url.path) else {
    throw XCTSkip("the fixture did not open")
  }

  return file
}

/// Waits for `condition` and fails the test with `message` when it never holds.
@MainActor
func expectEventually(
  _ message: String = "", file: StaticString = #filePath, line: UInt = #line,
  _ condition: @MainActor () -> Bool
) async {
  let held = await Harness.eventually(condition)

  XCTAssertTrue(held, message, file: file, line: line)
}
