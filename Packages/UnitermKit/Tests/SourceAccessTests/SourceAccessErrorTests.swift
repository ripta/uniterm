import Darwin
import XCTest

@testable import SourceAccess

final class SourceAccessErrorTests: XCTestCase {
  /// Catches an errno that maps to the wrong message. A missing path, a missing parent, and a
  /// refused read each say which, and any other errno keeps the system's own reason.
  func testErrnoMapsToMissingProtectedOrUnreadable() {
    XCTAssertEqual(SourceAccessError.posix(ENOENT, path: "/a/b"), .missing(path: "/a/b"))
    XCTAssertEqual(SourceAccessError.posix(ENOTDIR, path: "/a/b"), .missing(path: "/a/b"))
    XCTAssertEqual(SourceAccessError.posix(EACCES, path: "/a/b"), .permissionDenied(path: "/a/b"))
    XCTAssertEqual(SourceAccessError.posix(EPERM, path: "/a/b"), .permissionDenied(path: "/a/b"))

    guard case .unreadable(_, let reason) = SourceAccessError.posix(EIO, path: "/a/b") else {
      return XCTFail("EIO should be unreadable")
    }

    XCTAssertEqual(reason, String(cString: strerror(EIO)))
  }

  /// Catches a message that says "corrupt", or one that does not name the file. The wording of a
  /// permission refusal points at System Settings.
  func testMessagesNameTheFileAndNeverSayCorrupt() {
    let errors: [SourceAccessError] = [
      .missing(path: "/a/pins.geojson"), .permissionDenied(path: "/a/pins.geojson"),
      .notARegularFile(path: "/a/pins.geojson", kind: "a pipe"),
      .unreadable(path: "/a/pins.geojson", reason: "boom"),
    ]

    for error in errors {
      let text = error.errorDescription ?? ""

      XCTAssertTrue(text.contains("pins.geojson"), text)
      XCTAssertFalse(text.lowercased().contains("corrupt"), text)
    }

    XCTAssertTrue(errors[1].errorDescription?.contains("System Settings") ?? false)
  }

  /// Catches a mode that reads as the wrong kind.
  func testKindNamesTheIrregularFile() {
    XCTAssertEqual(SourceAccessError.kind(of: S_IFDIR), "a folder")
    XCTAssertEqual(SourceAccessError.kind(of: S_IFIFO), "a pipe")
    XCTAssertEqual(SourceAccessError.kind(of: S_IFSOCK), "a socket")
    XCTAssertEqual(SourceAccessError.kind(of: S_IFCHR), "a device")
  }
}
