import XCTest

@testable import AppletKit

/// The exec launch context as a declaration states it, and as one launch resolves it.
final class ExecDeclarationTests: XCTestCase {
  /// Catches a declaration that takes a relative program or directory, a shell-only name, or a
  /// key that is not a variable name.
  func testADeclarationRefusesWhatIsNotLiteralAndAbsolute() {
    let bad: [([String], String?, [String], ExecDeclarationError)] = [
      ([], nil, [], .noProgram),
      (["perl", "x"], nil, [], .relativeProgram("perl")),
      (["/usr/bin/perl"], "work", [], .relativeDirectory("work")),
      (["/usr/bin/perl"], nil, ["1BAD"], .badKey("1BAD")),
      (["/usr/bin/perl"], nil, ["A=B"], .badKey("A=B")),
      (["/usr/bin/perl", "a\0b"], nil, [], .nulByte),
    ]

    for (arguments, directory, keys, error) in bad {
      XCTAssertThrowsError(
        try ExecDeclaration(arguments: arguments, directory: directory, environmentKeys: keys)
      ) { XCTAssertEqual($0 as? ExecDeclarationError, error) }
    }
  }

  /// Catches a launch that runs with a declared key unset, takes a value the declaration does not
  /// name, or runs anywhere but the declared directory or home.
  func testALaunchNeedsEveryDeclaredValueAndNoOther() throws {
    let declaration = try ExecDeclaration(
      arguments: ["/usr/bin/true"], directory: nil, environmentKeys: ["TOKEN", "TOKEN"])

    XCTAssertEqual(declaration.environmentKeys, ["TOKEN"])

    XCTAssertThrowsError(try ExecLaunch(declaration: declaration, environment: [:], home: "/h")) {
      XCTAssertEqual($0 as? ExecDeclarationError, .missingValue("TOKEN"))
    }

    XCTAssertThrowsError(
      try ExecLaunch(
        declaration: declaration, environment: ["TOKEN": "x", "MORE": "y"], home: "/h")
    ) { XCTAssertEqual($0 as? ExecDeclarationError, .undeclaredValue("MORE")) }

    XCTAssertEqual(
      try ExecLaunch(declaration: declaration, environment: ["TOKEN": "x"], home: "/h").directory,
      "/h")
  }
}
