import AppletKit
import XCTest

@testable import WindowKit

/// The text a user reads before allowing a launch. It comes from a declaration a program may
/// have written, so it must show every input as it is and let none pose as another line.
final class LaunchApprovalTextTests: XCTestCase {
  /// Catches an argument or a value whose newline fakes a Directory or Pane line, or whose bidi
  /// override reorders what the user reads.
  func testArgumentsAndValuesCannotFakeLinesOrReorderText() throws {
    let declaration = try ExecDeclaration(
      arguments: ["/usr/bin/perl", "x\nDirectory: /fake", "a\u{202E}b", "tab\there", ""],
      directory: "/synthetic", environmentKeys: ["TOKEN"])
    let launch = try ExecLaunch(
      declaration: declaration, environment: ["TOKEN": "v\r\nPane: fake\u{2066}"], home: "/h")

    let text = LaunchApprovalText.request(launch, pane: "uniterm: Slides")
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

    XCTAssertEqual(lines.filter { $0.hasPrefix("Directory:") }, ["Directory: /synthetic"], text)
    XCTAssertEqual(lines.filter { $0.hasPrefix("Pane:") }, ["Pane: uniterm: Slides"], text)
    XCTAssertTrue(lines.contains("  argv[0] /usr/bin/perl"), text)
    XCTAssertTrue(lines.contains(#"  argv[1] x\nDirectory: /fake"#), text)
    XCTAssertTrue(lines.contains(#"  argv[2] a\u{202E}b"#), text)
    XCTAssertTrue(lines.contains(#"  argv[3] tab\there"#), text)
    XCTAssertTrue(lines.contains(#"  argv[4] (empty)"#), text)
    XCTAssertTrue(lines.contains(#"  TOKEN=v\r\nPane: fake\u{2066}"#), text)

    let unsafe = text.unicodeScalars.filter {
      ($0.value < 0x20 && $0 != "\n") || (0x202A...0x202E).contains($0.value)
        || (0x2066...0x2069).contains($0.value)
    }

    XCTAssertTrue(unsafe.isEmpty, "the text holds \(unsafe.map { String($0.value, radix: 16) })")
  }
}
