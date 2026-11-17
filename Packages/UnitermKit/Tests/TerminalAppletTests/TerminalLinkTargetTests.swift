import Darwin
import XCTest

@testable import TerminalApplet

/// The rules that decide what a click on terminal text may open. A program chose the text, so
/// every rule here is about refusing a path that is not exactly the file the user was shown.
final class TerminalLinkTargetTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appending(path: "uniterm-links-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  // MARK: Classification

  /// Catches an absolute path or a local file link that a click would refuse, and a file link
  /// whose percent escapes are not decoded before the path is compared.
  func testAnAbsolutePathAndALocalFileLinkOpenAsTheirDecodedPath() {
    XCTAssertEqual(TerminalLinkTarget.classify("/Users/me/a.txt"), .file("/Users/me/a.txt"))
    XCTAssertEqual(TerminalLinkTarget.classify("file:///Users/me/a.txt"), .file("/Users/me/a.txt"))
    XCTAssertEqual(TerminalLinkTarget.classify("FILE:///Users/me/a.txt"), .file("/Users/me/a.txt"))
    XCTAssertEqual(
      TerminalLinkTarget.classify("file://localhost/Users/me/a.txt"), .file("/Users/me/a.txt"))
    XCTAssertEqual(
      TerminalLinkTarget.classify("file://LocalHost/Users/me/a.txt"), .file("/Users/me/a.txt"))
    XCTAssertEqual(
      TerminalLinkTarget.classify("file:///Users/me/My%20Notes%20%C3%A9.txt"),
      .file("/Users/me/My Notes \u{E9}.txt"))
  }

  /// Catches a file link that names another host reaching a local file of the same path. The host
  /// is compared after the scheme, and an address is not the local host.
  func testAFileLinkNamingAnotherHostIsRefused() {
    for text in [
      "file://server.example/Users/me/a.txt", "file://127.0.0.1/Users/me/a.txt",
      "file://[::1]/Users/me/a.txt", "file://localhost.example/a", "file://host:22/a",
    ] {
      let target = TerminalLinkTarget.classify(text)
      XCTAssertTrue(
        target == .refused(.otherHost) || target == .refused(.notPlain), "\(text): \(target)")
    }

    XCTAssertEqual(
      TerminalLinkTarget.classify("file://server.example/Users/me/a.txt"), .refused(.otherHost))
  }

  /// Catches a relative path, a home path, and a variable path that a click would join to some
  /// directory. The text may come from a remote `ls` or from before a `cd`.
  func testARelativePathIsRefused() {
    for text in [
      "notes.txt", "./notes.txt", "../notes.txt", "src/notes.txt", "~/notes.txt", "~",
      "$HOME/notes.txt", "file:notes.txt",
    ] {
      XCTAssertEqual(TerminalLinkTarget.classify(text), .refused(.relative), text)
    }
  }

  /// Catches a click on a web address or another scheme that does anything.
  func testOtherSchemesAreNotFiles() {
    for text in [
      "https://example.com/a.txt", "http://example.com", "ssh://host/path", "mailto:a@b.example",
      "ftp://host/a", "",
    ] {
      XCTAssertEqual(TerminalLinkTarget.classify(text), .notAFile, text)
    }
  }

  /// Catches text that would show as another path in the overlay. Control and format characters
  /// hide or reorder text, a query or fragment is not part of a path, and a decoded control
  /// character is no better than a typed one.
  func testTextThatCouldShowAsAnotherPathIsRefused() {
    for text in [
      "/Users/me/a\u{0}b", "/Users/me/a\nb", "/Users/me/a\u{202E}txt.exe", "/Users/me/a\u{200B}b",
      "/Users/me/a\u{2028}b", "file:///Users/me/a.txt?x=1", "file:///Users/me/a.txt#L10",
      "file:///Users/me/a%0Ab", "file:///Users/me/a%E2%80%AEb", "file://user@localhost/a",
    ] {
      XCTAssertEqual(TerminalLinkTarget.classify(text), .refused(.notPlain), text.debugDescription)
    }
  }

  // MARK: Normalization

  /// Catches a comparison that treats `/tmp` and `/private/tmp` as different files. The system
  /// reports the real path under `/private` for all three aliases.
  func testThePrivateAliasesNormalizeToTheirTargets() {
    XCTAssertEqual(TerminalLinkTarget.normalized("/tmp/a"), "/private/tmp/a")
    XCTAssertEqual(TerminalLinkTarget.normalized("/var/folders/x"), "/private/var/folders/x")
    XCTAssertEqual(TerminalLinkTarget.normalized("/etc/hosts"), "/private/etc/hosts")
    XCTAssertEqual(TerminalLinkTarget.normalized("/tmp"), "/private/tmp")
    XCTAssertEqual(TerminalLinkTarget.normalized("/private/tmp/a"), "/private/tmp/a")
    XCTAssertEqual(TerminalLinkTarget.normalized("/tmp/dir/"), "/private/tmp/dir")
    XCTAssertEqual(TerminalLinkTarget.normalized("/"), "/")
  }

  /// Catches a prefix match that rewrites `/tmpfiles` or `/variable` as an alias.
  func testANameThatOnlyStartsLikeAnAliasIsLeftAlone() {
    XCTAssertEqual(TerminalLinkTarget.normalized("/tmpfiles/a"), "/tmpfiles/a")
    XCTAssertEqual(TerminalLinkTarget.normalized("/variable"), "/variable")
    XCTAssertEqual(TerminalLinkTarget.normalized("/Users/me/tmp/a"), "/Users/me/tmp/a")
  }

  // MARK: Verification

  private func makeFile(_ name: String, contents: String = "x") throws -> String {
    let url = root.appending(path: name)
    try contents.write(to: url, atomically: false, encoding: .utf8)
    return url.path
  }

  /// Catches a verifier that refuses a file the pane really showed. The temporary folder is under
  /// `/var`, so the printed path and the opened descriptor's path differ by the `/private` alias
  /// until both are normalized. A folder needs the same match.
  func testAFileAndAFolderThatAreWhatTheyShowPass() throws {
    let file = try makeFile("a.txt")

    XCTAssertNil(LinkClickVerifier.check(file))
    XCTAssertNil(LinkClickVerifier.check(root.path))
    XCTAssertNil(LinkClickVerifier.check(root.path + "/"))
  }

  /// Catches the printed-symlink attack. A link whose text reads like one file and leads to
  /// another is the case the shown target exists to stop. The link's target exists, so a verifier
  /// that follows links would open it.
  func testAPrintedSymlinkToAnotherFileOpensNothing() throws {
    let target = try makeFile("secret.txt")
    let link = root.appending(path: "readme.txt").path
    try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)

    XCTAssertEqual(LinkClickVerifier.check(link), .differs)
  }

  /// Catches a link to a folder, and a path that goes through a link to another folder. The
  /// last component is not a link there, so only the real path of the opened descriptor shows
  /// the difference.
  func testAPathThroughALinkedFolderOpensNothing() throws {
    let realFolder = root.appending(path: "real", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: realFolder, withIntermediateDirectories: true)
    _ = try makeFile("real/inner.txt")

    let linked = root.appending(path: "linked").path
    try FileManager.default.createSymbolicLink(
      atPath: linked, withDestinationPath: realFolder.path)

    XCTAssertEqual(LinkClickVerifier.check(linked), .differs)
    XCTAssertEqual(LinkClickVerifier.check(linked + "/inner.txt"), .differs)
    XCTAssertNil(LinkClickVerifier.check(realFolder.path + "/inner.txt"))
  }

  /// Catches a verifier that opens a path that is gone, or one that is neither a file nor a
  /// folder. A FIFO has no reader, and a plain open of it would block. A device node must not
  /// be opened either.
  func testAMissingPathAFifoAndADeviceOpenNothing() throws {
    XCTAssertEqual(LinkClickVerifier.check(root.path + "/missing"), .unavailable)

    let fifo = root.appending(path: "pipe").path
    XCTAssertEqual(mkfifo(fifo, 0o600), 0)
    XCTAssertEqual(LinkClickVerifier.check(fifo), .unavailable)

    XCTAssertEqual(LinkClickVerifier.check("/dev/null"), .unavailable)
  }

  /// Catches a path spelled with a doubled slash or a dot segment passing as the file it shows.
  /// The descriptor's path is canonical, so a different spelling must not match.
  func testAnOddSpellingOfARealPathIsNotTheShownPath() throws {
    let file = try makeFile("a.txt")

    XCTAssertEqual(LinkClickVerifier.check(root.path + "//a.txt"), .differs)
    XCTAssertEqual(LinkClickVerifier.check(root.path + "/./a.txt"), .differs)
    XCTAssertEqual(
      LinkClickVerifier.check(root.path + "/../" + root.lastPathComponent + "/a.txt"), .differs)
    XCTAssertNil(LinkClickVerifier.check(file))
  }

  /// Catches a path under a real alias that the verifier would call different. The alias `/tmp`
  /// is a link to `/private/tmp`, and a file there must open when shown as `/tmp/...`.
  func testAFileShownUnderTheTmpAliasPasses() throws {
    let name = "uniterm-alias-\(UUID().uuidString).txt"
    let path = "/tmp/\(name)"

    guard FileManager.default.createFile(atPath: path, contents: Data("x".utf8)) else {
      throw XCTSkip("/tmp is not writable here")
    }

    defer { try? FileManager.default.removeItem(atPath: path) }

    XCTAssertNil(LinkClickVerifier.check(path))
  }

  /// Catches a verifier that blocks the main actor. The async form hops off the caller.
  @MainActor
  func testTheAsyncCheckAnswersLikeTheSyncOne() async throws {
    let file = try makeFile("a.txt")

    let passed = await LinkClickVerifier.verify(file)
    let failed = await LinkClickVerifier.verify(root.path + "/missing")

    XCTAssertNil(passed)
    XCTAssertEqual(failed, .unavailable)
  }
}
