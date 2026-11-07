import XCTest

@testable import TerminalSurface

final class TerminalSurfaceInfoTests: XCTestCase {
  /// Proves the pinned libghostty links into the module and answers. It says nothing about
  /// terminal behavior.
  func testLinkedLibraryReportsPinnedVersion() {
    XCTAssertEqual(TerminalSurfaceInfo.libraryVersion, "1.4.0")
  }
}
