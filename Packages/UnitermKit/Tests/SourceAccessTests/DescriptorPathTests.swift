import Darwin
import XCTest

@testable import SourceAccess

/// The shared reader of a descriptor's real path. It catches a decode that drifts between the two
/// checks that use it. It cannot prove how either check judges the answer.
final class DescriptorPathTests: XCTestCase {
  func testAnOpenFileReportsItsRealPathThroughALink() throws {
    let scratch = try Scratch(self)

    try scratch.write("real.txt", "x")

    try FileManager.default.createSymbolicLink(
      atPath: scratch.url.appendingPathComponent("link.txt").path, withDestinationPath: "real.txt")

    let descriptor = open(scratch.url.appendingPathComponent("link.txt").path, O_RDONLY)

    XCTAssertGreaterThanOrEqual(descriptor, 0)
    defer { close(descriptor) }

    let expected = realpath(scratch.url.appendingPathComponent("real.txt").path, nil)

    defer { free(expected) }

    XCTAssertEqual(DescriptorPath.read(descriptor), String(cString: try XCTUnwrap(expected)))
    XCTAssertTrue(try XCTUnwrap(DescriptorPath.read(descriptor)).hasSuffix("/real.txt"))
  }

  func testAClosedDescriptorReportsNothing() {
    XCTAssertNil(DescriptorPath.read(-1))
  }

  func testANonASCIIPathDecodes() throws {
    let scratch = try Scratch(self)

    try scratch.write("caf\u{E9} \u{1F600}.txt", "x")

    let descriptor = open(
      scratch.url.appendingPathComponent("caf\u{E9} \u{1F600}.txt").path, O_RDONLY)

    defer { close(descriptor) }

    XCTAssertTrue(DescriptorPath.read(descriptor)?.hasSuffix(".txt") == true)
    XCTAssertTrue(DescriptorPath.read(descriptor)?.contains("\u{1F600}") == true)
  }
}
