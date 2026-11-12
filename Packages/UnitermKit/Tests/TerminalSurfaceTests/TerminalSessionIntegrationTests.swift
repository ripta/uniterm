import AppKit
import Theme
import XCTest

@testable import TerminalSurface

/// Runs a real zsh through the session protocol, inside a window that is never shown.
///
/// These tests start real shells, so each costs about a second. A mock cannot prove what they
/// prove: that libghostty injects shell integration, that the integration's OSC 7 and OSC 133
/// reach the protocol, and that the running-state query follows the prompt.
@MainActor
final class TerminalSessionIntegrationTests: XCTestCase {
  private var sandbox: URL!
  private var resources: URL!
  private var helper: URL!
  private var engine: GhosttyTerminalEngine!
  private var window: NSWindow!
  private var sessions: [any TerminalSession] = []
  private var savedEnvironment: [String: String?] = [:]
  private var baselineChildren: Set<pid_t> = []

  override func setUp() async throws {
    continueAfterFailure = false
    _ = NSApplication.shared

    sandbox = FileManager.default.temporaryDirectory.appending(
      path: "uniterm-session-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: sandbox.appending(path: "home"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: sandbox.appending(path: "work"), withIntermediateDirectories: true)
    try Data().write(to: sandbox.appending(path: "home/.zshrc"))

    resources = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appending(path: "Frameworks/GhosttyResources/ghostty")
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: resources.appending(path: "shell-integration").path),
      "run `make build` so Ghostty's resources exist")

    helper = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appending(path: "Support/ghostty-bin", directoryHint: .isDirectory)
    XCTAssertTrue(
      FileManager.default.isExecutableFile(atPath: helper.appending(path: "ghostty").path),
      "uniterm's ghostty helper is missing or not executable")

    // The shell must not read the developer's dotfiles, which may prompt for an ssh passphrase.
    // ZDOTDIR goes in the process environment, since Ghostty's zsh integration reads it there and
    // restores it for the user's startup files. A ZDOTDIR passed as a launch variable would
    // override the integration's own.
    for name in [
      "SHELL", "ZDOTDIR", "SSH_AUTH_SOCK", "SSH_ASKPASS", "MAKEFLAGS", "GHOSTTY_RESOURCES_DIR",
    ] {
      savedEnvironment[name] = getenv(name).map { String(cString: $0) }
    }

    setenv("SHELL", "/bin/zsh", 1)
    setenv("ZDOTDIR", sandbox.appending(path: "home").path, 1)
    setenv("SSH_AUTH_SOCK", "", 1)
    unsetenv("SSH_ASKPASS")
    engine = try GhosttyTerminalEngine(
      configStore: TerminalConfigStore(directory: sandbox.appending(path: "config")),
      resourcesDirectory: resources, helperDirectory: helper, palette: .latte)

    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    baselineChildren = Set(children(of: getpid()))
  }

  override func tearDown() async throws {
    // A program a test starts can outlive its session. Everything the test process started since
    // setUp is ended, children first, so no test leaves an orphan.
    let started = Set(children(of: getpid())).subtracting(baselineChildren)
    let stragglers = started.flatMap { tree(of: $0) }

    for session in sessions {
      session.close()
    }
    sessions = []

    for pid in stragglers.reversed() {
      kill(pid, SIGKILL)
    }
    engine = nil
    window.close()
    try? FileManager.default.removeItem(at: sandbox)

    for (name, value) in savedEnvironment {
      if let value {
        setenv(name, value, 1)
      } else {
        unsetenv(name)
      }
    }
    savedEnvironment = [:]
  }

  private func startShell(policy: TerminalClipboardPolicy = .interactive) throws
    -> any TerminalSession
  {
    let launch = TerminalLaunch.loginShell(
      workingDirectory: sandbox.appending(path: "work").path,
      environment: ["HOME": sandbox.appending(path: "home").path])
    return host(try engine.makeSession(launch: launch, clipboardPolicy: policy))
  }

  private func startProgram(_ words: [String]) throws -> any TerminalSession {
    let launch = TerminalLaunch.program(
      words, workingDirectory: sandbox.appending(path: "work").path)
    return host(try engine.makeSession(launch: launch, clipboardPolicy: .interactive))
  }

  private func host(_ session: any TerminalSession) -> any TerminalSession {
    sessions.append(session)

    session.view.frame = window.contentView!.bounds
    window.contentView!.addSubview(session.view)
    session.setFocused(true)
    return session
  }

  private func waitUntil(
    _ description: String, timeout: Duration = .seconds(20), _ condition: () -> Bool
  ) async throws {
    let deadline = ContinuousClock.now + timeout

    while !condition() {
      if ContinuousClock.now > deadline {
        XCTFail("timed out waiting for \(description). Screen:\n\(sessions.last.map(screen) ?? "")")
        throw CancellationError()
      }

      try await Task.sleep(for: .milliseconds(25))
    }
  }

  /// `send(text:)` pastes, and a shell does not run a pasted newline. Enter is a real key event.
  private func press(
    _ session: any TerminalSession, keyCode: UInt16, characters: String,
    modifiers: NSEvent.ModifierFlags = []
  ) throws {
    for type in [NSEvent.EventType.keyDown, .keyUp] {
      let event = try XCTUnwrap(
        NSEvent.keyEvent(
          with: type, location: .zero, modifierFlags: modifiers, timestamp: 0,
          windowNumber: window.windowNumber, context: nil, characters: characters,
          charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))

      if type == .keyDown {
        session.view.keyDown(with: event)
      } else {
        session.view.keyUp(with: event)
      }
    }
  }

  private func run(_ command: String, in session: any TerminalSession) throws {
    session.send(text: command)
    try press(session, keyCode: 0x24, characters: "\r")
  }

  private func screen(_ session: any TerminalSession) -> String {
    session.view.accessibilityValue() as? String ?? ""
  }

  /// Catches shell integration that never reaches the protocol, and a running-state query that
  /// does not follow the prompt. The shell reports its directory with OSC 7, which starts at the
  /// first prompt. The query is false there, true while vim runs, and false again after vim quits.
  func testRunningStateFollowsThePromptAndVim() async throws {
    let session = try startShell()
    var directories: [String] = []
    session.onEvent = { event in
      if case .workingDirectoryChanged(let path) = event { directories.append(path) }
    }

    try await waitUntil("the first prompt's working directory") { !directories.isEmpty }
    try await waitUntil("an idle prompt") { !session.isRunningSomething }

    let expected = sandbox.appending(path: "work").resolvingSymlinksInPath().path
    XCTAssertEqual(URL(fileURLWithPath: directories[0]).resolvingSymlinksInPath().path, expected)

    try run("vim -u NONE -N", in: session)
    try await waitUntil("vim's screen") {
      let text = self.screen(session)
      return text.contains("VIM - Vi IMproved")
        || text.split(separator: "\n").filter { $0.hasPrefix("~") }.count >= 3
    }

    try await Task.sleep(for: .milliseconds(500))
    XCTAssertTrue(session.isRunningSomething, "vim is up and the query says idle")

    try press(session, keyCode: 0x35, characters: "\u{1B}")
    try press(session, keyCode: 0x29, characters: ":", modifiers: .shift)
    try press(session, keyCode: 0x0C, characters: "q")
    try press(session, keyCode: 0x12, characters: "!", modifiers: .shift)
    try press(session, keyCode: 0x24, characters: "\r")
    try await waitUntil("the prompt after vim") { !session.isRunningSomething }
  }

  /// Catches OSC 133 marks that never arrive. The shell reports a finished command's exit status,
  /// and the working directory follows `cd`.
  func testCommandFinishedAndDirectoryChangeReachTheProtocol() async throws {
    let session = try startShell()
    var finished: [Int?] = []
    var directories: [String] = []
    session.onEvent = { event in
      switch event {
      case .commandFinished(let code, _): finished.append(code)
      case .workingDirectoryChanged(let path): directories.append(path)
      default: break
      }
    }

    try await waitUntil("an idle prompt") { !session.isRunningSomething && !directories.isEmpty }

    try run("false", in: session)
    try await waitUntil("the exit status of false") { finished.contains(1) }

    try run("true", in: session)
    try await waitUntil("the exit status of true") { finished.contains(0) }

    let target = sandbox.appending(path: "home").resolvingSymlinksInPath().path
    try run("cd \(target)", in: session)
    try await waitUntil("OSC 7 after cd") {
      directories.contains { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path == target }
    }
  }

  /// Catches a missing terminfo or a TERM other than xterm-ghostty. Also checks that the `ssh`
  /// wrapper from the `ssh-env` feature exists, and that a program started by ssh sees
  /// TERM=xterm-256color. The probe uses ssh's ProxyCommand, which runs locally with ssh's own
  /// environment, so no remote host is needed. A real host without the terminfo entry is not
  /// reachable from here.
  ///
  /// Ghostty's wrapper runs `$GHOSTTY_BIN_DIR/ghostty +ssh`, so this also catches a shell whose
  /// `GHOSTTY_BIN_DIR` is not uniterm's helper, whose `PATH` gained uniterm's executable directory,
  /// and a helper that stops forwarding the terminal variables. `ssh -G` prints the options the
  /// helper added without connecting.
  func testTermTerminfoAndSshFallback() async throws {
    let session = try startShell()
    try await waitUntil("an idle prompt") { !session.isRunningSomething }

    try run(
      "echo \"T:$TERM:\"; infocmp xterm-ghostty >/dev/null && echo \"I:$((6*7)):\"", in: session)
    try await waitUntil("TERM and infocmp output") {
      let text = self.screen(session)
      return text.contains("T:xterm-ghostty:") && text.contains("I:42:")
    }

    try run("whence -w ssh", in: session)
    try await waitUntil("the ssh wrapper") { self.screen(session).contains("ssh: function") }

    try run(
      "ssh -F /dev/null -o BatchMode=yes -o ProxyCommand='echo \"PT:$TERM:\" >&2; exit 1' nowhere",
      in: session)
    try await waitUntil("the TERM that ssh passes on") {
      self.screen(session).contains("PT:xterm-256color:")
    }

    try run(
      "ssh -F /dev/null -G nowhere | grep -c '^sendenv TERM_PROGRAM' | sed 's/^/SE:/'", in: session)
    try await waitUntil("the forwarded variables") { self.screen(session).contains("SE:2") }

    let executableDirectory = Bundle.main.executableURL!.deletingLastPathComponent().path
    try run(
      #"[ "$GHOSTTY_BIN_DIR" = '\#(helper.path)' ] && echo "BD:$((6*7)):"; "#
        + #"case ":$PATH:" in *':\#(executableDirectory):'*) ;; *) echo "PA:$((5*5)):" ;; esac"#,
      in: session)
    try await waitUntil("the helper and PATH checks") {
      let text = self.screen(session)
      return text.contains("BD:42:") && text.contains("PA:25:")
    }
  }

  /// Catches a resize that never reaches the shell. The shell's own `stty size` reports the grid.
  ///
  /// libghostty applies a resize to the pty 25 ms later, so a command typed right after the resize
  /// can still see the old size. The script waits for the SIGWINCH that the kernel sends once the
  /// size changes, and only then asks.
  func testShellSeesTheNewSize() async throws {
    let script = sandbox.appending(path: "winch-\(getpid()).sh")
    try """
    trap 'stty size | sed "s/^/S:/;s/ /x/"; kill "$pid"; exit' WINCH
    sleep 30 &
    pid=$!
    printf 'W:%s\\n' ready
    wait "$pid"
    """.write(to: script, atomically: true, encoding: .utf8)

    let session = try startShell()
    try await waitUntil("an idle prompt") { !session.isRunningSomething }

    let before = session.gridSize
    XCTAssertGreaterThan(before.columns, 20)

    try run("sh '\(script.path)'", in: session)
    try await waitUntil("the size watcher") { self.screen(session).contains("W:ready") }

    session.resize(to: CGSize(width: 400, height: 200))

    let after = session.gridSize
    XCTAssertLessThan(after.columns, before.columns)
    XCTAssertLessThan(after.rows, before.rows)

    let expected = "S:\(after.rows)x\(after.columns)"
    try await waitUntil("stty to report \(expected)") { self.screen(session).contains(expected) }
  }

  /// Catches a pane that stays open after its shell ends.
  func testShellExitEmitsExited() async throws {
    let session = try startShell()
    var exited = false
    session.onEvent = { event in
      if case .exited = event { exited = true }
    }
    try await waitUntil("an idle prompt") { !session.isRunningSomething }

    try run("exit", in: session)
    try await waitUntil("the exit event") { exited }
    XCTAssertTrue(session.hasExited)
  }

  /// Catches font zoom that does not reach the surface. A bigger font fits fewer columns, and
  /// reset brings the grid back.
  func testFontZoomChangesTheGridAndResets() async throws {
    let session = try startShell()
    try await waitUntil("an idle prompt") { !session.isRunningSomething }
    let original = session.gridSize

    session.perform(.increaseFontSize)
    session.perform(.increaseFontSize)
    XCTAssertLessThan(session.gridSize.columns, original.columns)

    session.perform(.decreaseFontSize)
    session.perform(.decreaseFontSize)
    session.perform(.decreaseFontSize)
    XCTAssertGreaterThan(session.gridSize.columns, original.columns)

    session.perform(.resetFontSize)
    XCTAssertEqual(session.gridSize, original)
  }

  /// Catches copy, paste, and select all that do not work through the protocol. The pasteboard is
  /// saved and restored, since libghostty uses the general one.
  func testCopyPasteAndSelectAll() async throws {
    let saved = NSPasteboard.general.string(forType: .string)
    defer {
      NSPasteboard.general.clearContents()
      if let saved { NSPasteboard.general.setString(saved, forType: .string) }
    }

    let session = try startShell()
    try await waitUntil("an idle prompt") { !session.isRunningSomething }

    try run("echo \"K:$((40+2)):\"", in: session)
    try await waitUntil("the marker") { self.screen(session).contains("K:42:") }

    NSPasteboard.general.clearContents()
    session.perform(.selectAll)
    session.perform(.copy)
    try await waitUntil("the copied text") {
      NSPasteboard.general.string(forType: .string)?.contains("K:42:") == true
    }

    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString("echo \"P:$((6*7)):\"", forType: .string)
    session.perform(.paste)
    try press(session, keyCode: 0x24, characters: "\r")
    try await waitUntil("the pasted command's output") { self.screen(session).contains("P:42:") }
  }

  /// Catches OSC 9 and OSC 777 notifications that do not reach the protocol.
  func testNotificationsReachTheProtocol() async throws {
    let session = try startShell()
    var notes: [String] = []
    session.onEvent = { event in
      if case .notification(let title, let body) = event { notes.append("\(title)|\(body)") }
    }
    try await waitUntil("an idle prompt") { !session.isRunningSomething }

    try run("printf '\\033]9;nine-body\\a'", in: session)
    try await waitUntil("the OSC 9 notification") { !notes.isEmpty }

    // libghostty allows one notification per second.
    try await Task.sleep(for: .milliseconds(1_200))
    try run("printf '\\033]777;notify;sevens-title;sevens-body\\a'", in: session)
    try await waitUntil("the OSC 777 notification") { notes.count >= 2 }

    XCTAssertTrue(notes.contains("|nine-body"), "got \(notes)")
    XCTAssertTrue(notes.contains("sevens-title|sevens-body"))
  }

  /// Catches an OSC 52 clipboard read that is answered before the user decides. The request waits.
  /// While it waits, the program receives nothing. An allowed request then sends the clipboard, and
  /// a denied one sends none of it.
  func testClipboardReadIsNeverAnsweredWithoutConfirmation() async throws {
    let saved = NSPasteboard.general.string(forType: .string)
    defer {
      NSPasteboard.general.clearContents()
      if let saved { NSPasteboard.general.setString(saved, forType: .string) }
    }

    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString("SECRET-CB", forType: .string)
    let encoded = Data("SECRET-CB".utf8).base64EncodedString()

    let session = try startShell()
    var requests: [TerminalClipboardRequest] = []
    session.onEvent = { event in
      if case .clipboardRequest(let request) = event { requests.append(request) }
    }
    try await waitUntil("an idle prompt") { !session.isRunningSomething }

    // The shell reads the terminal's reply itself, so the output shows what the program received.
    let ask =
      "printf '\\033]52;c;?\\a'; IFS= read -rs -t 8 -d $'\\\\' reply; echo \"G:${reply#*;c;}:\""

    try run(ask, in: session)
    try await waitUntil("the clipboard request") { !requests.isEmpty }
    XCTAssertEqual(requests[0].kind, .read)

    try await Task.sleep(for: .seconds(1))
    XCTAssertTrue(session.isRunningSomething, "the program got its answer before confirmation")
    XCTAssertFalse(screen(session).contains(encoded), "the clipboard was sent before confirmation")

    requests[0].resolve(allow: false)
    try await waitUntil("the read to finish after a denial") { !session.isRunningSomething }
    XCTAssertFalse(screen(session).contains(encoded), "a denied read still sent the clipboard")

    try run(ask, in: session)
    try await waitUntil("the second request") { requests.count == 2 }
    requests[1].resolve(allow: true)
    try await waitUntil("the clipboard after confirmation") {
      self.screen(session).contains(encoded)
    }
  }

  /// Catches a Kitty clipboard read that is answered, or that asks the user, instead of being
  /// denied. Both a read for text and a read for the type names alone must get an `EPERM` status.
  /// The second kind reaches no confirm callback, so it proves the denial in the read callback.
  func testKittyClipboardReadsAreDenied() async throws {
    let saved = NSPasteboard.general.string(forType: .string)
    defer {
      NSPasteboard.general.clearContents()
      if let saved { NSPasteboard.general.setString(saved, forType: .string) }
    }

    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString("SECRET-KITTY", forType: .string)
    let encoded = Data("SECRET-KITTY".utf8).base64EncodedString()

    let session = try startShell()
    var requests: [TerminalClipboardRequest] = []
    session.onEvent = { event in
      if case .clipboardRequest(let request) = event { requests.append(request) }
    }
    try await waitUntil("an idle prompt") { !session.isRunningSomething }

    // The payload names the MIME types, base64 encoded: "text/plain", then "." for the type names.
    let reads = [("T", "dGV4dC9wbGFpbg=="), ("L", "Lg==")]
    for (marker, payload) in reads {
      try run(
        "printf '\\033]5522;type=read;\(payload)\\a'; IFS= read -rs -t 8 -d $'\\a' reply; "
          + "echo \"\(marker):${reply#*status=}:\"", in: session)
      try await waitUntil("the \(marker) reply") {
        self.screen(session).contains("\(marker):EPERM:")
      }
    }

    XCTAssertTrue(requests.isEmpty, "a Kitty read asked the user")
    XCTAssertFalse(screen(session).contains(encoded), "a Kitty read received the clipboard")
  }

  /// Catches an OSC 52 write that asks the user, or that stops landing, now that `clipboard-write`
  /// is `ask`. It also catches a Kitty write that reaches the pasteboard instead of an `EPERM`.
  func testOSC52WritesLandAndKittyWritesAreDenied() async throws {
    let saved = NSPasteboard.general.string(forType: .string)
    defer {
      NSPasteboard.general.clearContents()
      if let saved { NSPasteboard.general.setString(saved, forType: .string) }
    }

    NSPasteboard.general.clearContents()

    let session = try startShell()
    var requests: [TerminalClipboardRequest] = []
    session.onEvent = { event in
      if case .clipboardRequest(let request) = event { requests.append(request) }
    }
    try await waitUntil("an idle prompt") { !session.isRunningSomething }

    let osc52 = Data("WROTE-52".utf8).base64EncodedString()
    try run("printf '\\033]52;c;\(osc52)\\a'", in: session)
    try await waitUntil("the OSC 52 write") {
      NSPasteboard.general.string(forType: .string) == "WROTE-52"
    }

    // A Kitty write is a begin packet, a data packet for each MIME type, and an empty commit.
    let kitty = Data("WROTE-KITTY".utf8).base64EncodedString()
    try run(
      "printf '\\033]5522;type=write\\a\\033]5522;type=wdata:mime=dGV4dC9wbGFpbg==;\(kitty)\\a"
        + "\\033]5522;type=wdata\\a'; IFS= read -rs -t 8 -d $'\\a' reply; "
        + "echo \"W:${reply#*status=}:\"", in: session)
    try await waitUntil("the Kitty write reply") { self.screen(session).contains("W:EPERM:") }

    XCTAssertEqual(NSPasteboard.general.string(forType: .string), "WROTE-52")
    XCTAssertTrue(requests.isEmpty, "a clipboard write asked the user")
  }

  /// Catches a controlled session whose OSC 52 write lands without asking, a denial that still
  /// writes, and a session permission that does not cover the next write. The writes arrive
  /// through libghostty's own write callback, with its confirm flag set. A controlled read asks
  /// too, and its session permission answers the next read without asking.
  func testAControlledSessionAsksBeforeOSC52WritesAndReads() async throws {
    let saved = NSPasteboard.general.string(forType: .string)
    defer {
      NSPasteboard.general.clearContents()
      if let saved { NSPasteboard.general.setString(saved, forType: .string) }
    }

    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString("BEFORE", forType: .string)

    let session = try startShell(policy: TerminalClipboardPolicy(controlled: true, generation: 1))
    var requests: [TerminalClipboardRequest] = []
    session.onEvent = { event in
      if case .clipboardRequest(let request) = event { requests.append(request) }
    }
    try await waitUntil("an idle prompt") { !session.isRunningSomething }

    func write(_ text: String) throws {
      try run("printf '\\033]52;c;\(Data(text.utf8).base64EncodedString())\\a'", in: session)
    }

    try write("W-DENIED")
    try await waitUntil("the first write request") { requests.count == 1 }
    XCTAssertEqual(requests[0].kind, .write)
    XCTAssertTrue(requests[0].offersSession)
    requests[0].resolve(.deny)

    try await Task.sleep(for: .milliseconds(500))
    XCTAssertEqual(NSPasteboard.general.string(forType: .string), "BEFORE", "a denied write landed")

    try write("W-ONCE")
    try await waitUntil("the second write request") { requests.count == 2 }
    requests[1].resolve(.allowOnce)
    try await waitUntil("the write allowed once") {
      NSPasteboard.general.string(forType: .string) == "W-ONCE"
    }

    try write("W-SESSION")
    try await waitUntil("a write after allow once to ask again") { requests.count == 3 }
    requests[2].resolve(.allowForSession)
    try await waitUntil("the write allowed for the session") {
      NSPasteboard.general.string(forType: .string) == "W-SESSION"
    }

    try write("W-FREE")
    try await waitUntil("a write the session covers") {
      NSPasteboard.general.string(forType: .string) == "W-FREE"
    }
    XCTAssertEqual(requests.count, 3, "a write the session covers asked again")

    let encoded = Data("W-FREE".utf8).base64EncodedString()
    let ask =
      "printf '\\033]52;c;?\\a'; IFS= read -rs -t 8 -d $'\\\\' reply; echo \"G:${reply#*;c;}:\""

    try run(ask, in: session)
    try await waitUntil("the read request") { requests.count == 4 }
    XCTAssertEqual(requests[3].kind, .read)
    XCTAssertTrue(requests[3].offersSession)
    requests[3].resolve(.allowForSession)
    try await waitUntil("the read allowed for the session") {
      self.screen(session).contains("G:\(encoded)")
    }

    try run(ask.replacingOccurrences(of: "G:", with: "H:"), in: session)
    try await waitUntil("a read the session covers") {
      self.screen(session).contains("H:\(encoded)")
    }
    XCTAssertEqual(requests.count, 4, "a read the session covers asked again")
  }

  /// Catches a program that floods a controlled session with OSC 52 writes and queues one prompt
  /// for each. While a write's prompt waits, every later write is denied at once, with no prompt,
  /// and none of them reaches the clipboard. Once the prompt is answered, the next write asks.
  func testAFloodOfControlledWritesAsksOnceAndChangesNothing() async throws {
    let saved = NSPasteboard.general.string(forType: .string)
    defer {
      NSPasteboard.general.clearContents()
      if let saved { NSPasteboard.general.setString(saved, forType: .string) }
    }

    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString("BEFORE-FLOOD", forType: .string)

    let session = try startShell(policy: TerminalClipboardPolicy(controlled: true, generation: 1))
    var requests: [TerminalClipboardRequest] = []
    session.onEvent = { event in
      if case .clipboardRequest(let request) = event { requests.append(request) }
    }
    try await waitUntil("an idle prompt") { !session.isRunningSomething }

    let flood = (1...20).map { "\\033]52;c;\(Data("FLOOD-\($0)".utf8).base64EncodedString())\\a" }

    try run("printf '\(flood.joined())'; echo FLOOD-$((1 + 1))-DONE", in: session)
    try await waitUntil("the flood to finish") { self.screen(session).contains("FLOOD-2-DONE") }
    try await Task.sleep(for: .milliseconds(500))

    XCTAssertEqual(requests.count, 1, "a flood of writes queued a prompt for each")
    XCTAssertEqual(NSPasteboard.general.string(forType: .string), "BEFORE-FLOOD")

    requests[0].resolve(.deny)
    try await Task.sleep(for: .milliseconds(300))
    XCTAssertEqual(NSPasteboard.general.string(forType: .string), "BEFORE-FLOOD")

    try run("printf '\\033]52;c;\(Data("AFTER".utf8).base64EncodedString())\\a'", in: session)
    try await waitUntil("a write after the answer to ask") { requests.count == 2 }
    requests[1].resolve(.deny)
  }

  /// Catches an answer that releases data or writes after the session's policy changed under it,
  /// or after the session closed. A pending write and a pending read are each answered allow once
  /// after the change, and neither the clipboard nor the program gets anything.
  func testAPendingClipboardAnswerIsStaleAfterAPolicyChangeOrAClose() async throws {
    let saved = NSPasteboard.general.string(forType: .string)
    defer {
      NSPasteboard.general.clearContents()
      if let saved { NSPasteboard.general.setString(saved, forType: .string) }
    }

    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString("SECRET-STALE", forType: .string)

    let session = try startShell(policy: TerminalClipboardPolicy(controlled: true, generation: 1))
    var requests: [TerminalClipboardRequest] = []
    session.onEvent = { event in
      if case .clipboardRequest(let request) = event { requests.append(request) }
    }
    try await waitUntil("an idle prompt") { !session.isRunningSomething }

    let encoded = Data("SECRET-STALE".utf8).base64EncodedString()
    let ask =
      "printf '\\033]52;c;?\\a'; IFS= read -rs -t 8 -d $'\\\\' reply; echo \"G:${reply#*;c;}:\""

    try run(ask, in: session)
    try await waitUntil("the read request") { requests.count == 1 }

    session.setClipboardPolicy(TerminalClipboardPolicy(controlled: false, generation: 2))
    requests[0].resolve(.allowOnce)

    try await waitUntil("the read to finish after a stale answer") {
      !session.isRunningSomething
    }
    XCTAssertFalse(screen(session).contains(encoded), "a stale read sent the clipboard")

    let written = Data("W-STALE".utf8).base64EncodedString()

    session.setClipboardPolicy(TerminalClipboardPolicy(controlled: true, generation: 3))
    try run("printf '\\033]52;c;\(written)\\a'", in: session)
    try await waitUntil("the write request") { requests.count == 2 }

    session.setClipboardPolicy(TerminalClipboardPolicy(controlled: true, generation: 4))
    requests[1].resolve(.allowOnce)

    try await Task.sleep(for: .milliseconds(500))
    XCTAssertEqual(
      NSPasteboard.general.string(forType: .string), "SECRET-STALE", "a stale write landed")

    try run("printf '\\033]52;c;\(written)\\a'", in: session)
    try await waitUntil("the write request before the close") { requests.count == 3 }

    session.close()
    requests[2].resolve(.allowOnce)

    try await Task.sleep(for: .milliseconds(500))
    XCTAssertEqual(
      NSPasteboard.general.string(forType: .string), "SECRET-STALE",
      "an answer after the session closed wrote the clipboard")
  }

  /// Catches libghostty bindings that survive in the generated config. With them, Cmd-Z, Cmd-W,
  /// Cmd-T, Cmd-D, and Cmd-Q would be taken by the terminal before uniterm's menu.
  func testBuiltInBindingsAreCleared() throws {
    let session = try startShell()
    let view = try XCTUnwrap(session.view as? GhosttySurfaceView)

    let keys: [(UInt16, Character)] = [
      (0x06, "z"), (0x0D, "w"), (0x11, "t"), (0x02, "d"), (0x0C, "q"),
    ]
    for (code, character) in keys {
      XCTAssertFalse(
        view.isLibraryBinding(keyCode: code, character: character, mods: .command),
        "Cmd-\(character) is still a libghostty binding")
    }
  }

  private var configFile: URL {
    sandbox.appending(path: "config/ghostty-\(getpid()).conf")
  }

  /// Catches a palette change that never reaches a running surface. The engine writes the new
  /// config, and libghostty announces that it applied it to the surface. The announcement stops
  /// when the `ghostty_app_update_config` call is removed.
  ///
  /// What this cannot prove is the color on screen, since libghostty has no call to read a
  /// surface's colors. That stays a check for the user.
  func testPaletteChangeReachesTheConfigFileAndTheRunningSurface() async throws {
    let session = try startShell()
    let view = try XCTUnwrap(session.view as? GhosttySurfaceView)
    let latte = try String(contentsOf: configFile, encoding: .utf8)
    XCTAssertTrue(latte.contains("background = #eff1f5"))

    let before = view.configChangeCount
    try engine.apply(palette: .mocha)

    let mocha = try String(contentsOf: configFile, encoding: .utf8)
    XCTAssertTrue(mocha.contains("background = #1e1e2e"))
    XCTAssertFalse(mocha.contains("background = #eff1f5"))
    try await waitUntil("the surface to apply the Mocha config") { view.configChangeCount > before }

    let afterMocha = view.configChangeCount
    try engine.apply(palette: .latte)
    try await waitUntil("the surface to apply the Latte config") {
      view.configChangeCount > afterMocha
    }
    XCTAssertTrue(try String(contentsOf: configFile, encoding: .utf8).contains("#eff1f5"))
  }

  /// An equal palette is skipped, so the surface is not told twice.
  func testApplyingTheSamePaletteTwiceDoesNotReloadTheSurface() async throws {
    let session = try startShell()
    let view = try XCTUnwrap(session.view as? GhosttySurfaceView)

    try engine.apply(palette: .latte)
    try await Task.sleep(for: .milliseconds(300))

    XCTAssertEqual(view.configChangeCount, 0)
  }

  /// The direct children of a process, by pid. The unused tail of the buffer stays zero.
  private func children(of parent: pid_t) -> [pid_t] {
    var buffer = [pid_t](repeating: 0, count: 256)
    let result = proc_listchildpids(parent, &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
    return result > 0 ? Array(buffer.prefix { $0 > 0 }) : []
  }

  private func tree(of root: pid_t) -> [pid_t] {
    var found = [root]
    var index = 0

    while index < found.count {
      for child in children(of: found[index]) where !found.contains(child) {
        found.append(child)
      }

      index += 1
    }

    return found
  }

  /// Guards the main thread against a hung close. libghostty hangs the child up with SIGHUP and
  /// loops until the child it tracks is gone. A shell that ignores SIGHUP might keep that loop
  /// running for good, and the free runs on the main thread.
  ///
  /// The trace found no hang. libghostty tracks `login(1)`, which exits on SIGHUP, so `close()`
  /// returns at once. The shell and its `sleep` survive, as `nohup` work does after any terminal
  /// closes. This test passed before any change and stays as a guard. A rescue kills the tree
  /// after 8 seconds so that a regression cannot hang the suite. The test ends the tree itself.
  func testCloseReturnsWhenTheChildIgnoresSIGHUP() async throws {
    let before = Set(children(of: getpid()))
    let session = try startShell()
    try await waitUntil("an idle prompt") { !session.isRunningSomething }

    let child = try XCTUnwrap(
      Set(children(of: getpid())).subtracting(before).first, "the session's child was not found")

    try run("trap '' HUP; sleep 1000", in: session)
    try await waitUntil("sleep to run") { session.isRunningSomething }
    try await Task.sleep(for: .milliseconds(300))

    let members = tree(of: child)
    XCTAssertGreaterThan(members.count, 2, "no sleep under the shell")
    defer {
      for pid in members.reversed() {
        kill(pid, SIGKILL)
      }
    }

    let rescue = DispatchWorkItem {
      for pid in members.reversed() {
        kill(pid, SIGKILL)
      }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: rescue)

    let started = ContinuousClock.now
    session.close()
    rescue.cancel()
    let elapsed = ContinuousClock.now - started

    XCTAssertLessThan(elapsed, .seconds(3), "close() blocked the main thread for \(elapsed)")
  }

  /// Catches a spawned shell that cannot use the home folder, as a sandbox would force. The shell
  /// writes a file under `$HOME`, reads it back, and the file is removed.
  func testShellCanReadAndWriteHome() async throws {
    let name = ".uniterm-test-\(UUID().uuidString)"
    let file = FileManager.default.homeDirectoryForCurrentUser.appending(path: name)
    defer { try? FileManager.default.removeItem(at: file) }

    let session = try startShell()
    try await waitUntil("an idle prompt") { !session.isRunningSomething }

    let token = "wrote-\(UUID().uuidString.prefix(8))"
    try run(
      "printf %s \(token) > \"$HOME/\(name)\" && echo \"H:$(cat \"$HOME/\(name)\"):\"", in: session)
    try await waitUntil("the file's contents") { self.screen(session).contains("H:\(token):") }

    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), token)
  }

  /// Catches a real key path that drops the apostrophe. keyCode 39 then Space types an apostrophe
  /// on US and on US Extended, where the apostrophe is a dead key that Space completes. The
  /// events go through `keyDown` and the text input system, as typing does.
  func testApostropheTypedThroughKeyDownReachesTheShell() async throws {
    let session = try startShell()
    try await waitUntil("an idle prompt") { !session.isRunningSomething }

    try press(session, keyCode: 39, characters: "'")
    try press(session, keyCode: 49, characters: " ")

    try await waitUntil("an apostrophe at the prompt") { self.screen(session).contains("% '") }
  }

  /// The menu reaches the terminal with a nil target, so AppKit finds `copy:` and the others on
  /// the first responder and asks `validateMenuItem` whether to enable them. This drives that path
  /// in-process. The pasteboard is saved and restored.
  func testMenuActionsReachTheFocusedTerminal() async throws {
    let saved = NSPasteboard.general.string(forType: .string)
    defer {
      NSPasteboard.general.clearContents()
      if let saved { NSPasteboard.general.setString(saved, forType: .string) }
    }

    let session = try startShell()
    let view = try XCTUnwrap(session.view as? GhosttySurfaceView)
    XCTAssertTrue(window.makeFirstResponder(view))
    try await waitUntil("an idle prompt") { !session.isRunningSomething }

    let copyItem = NSMenuItem(
      title: "Copy", action: #selector(TerminalMenuActions.copy(_:)), keyEquivalent: "c")
    XCTAssertFalse(view.validateMenuItem(copyItem), "Copy is enabled with nothing selected")

    try run("echo \"M:$((6*7)):\"", in: session)
    try await waitUntil("the marker") { self.screen(session).contains("M:42:") }

    XCTAssertTrue(view.tryToPerform(#selector(TerminalMenuActions.selectAll(_:)), with: nil))
    XCTAssertTrue(view.validateMenuItem(copyItem), "Copy is disabled with a selection")

    NSPasteboard.general.clearContents()
    XCTAssertTrue(view.tryToPerform(#selector(TerminalMenuActions.copy(_:)), with: nil))
    try await waitUntil("the copied text") {
      NSPasteboard.general.string(forType: .string)?.contains("M:42:") == true
    }

    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString("echo \"V:$((5*9)):\"", forType: .string)
    XCTAssertTrue(view.tryToPerform(#selector(TerminalMenuActions.paste(_:)), with: nil))
    try press(session, keyCode: 0x24, characters: "\r")
    try await waitUntil("the pasted command's output") { self.screen(session).contains("V:45:") }

    // On a 1x display one step can round to the same cell width, so the font grows by two.
    let columns = session.gridSize.columns
    for _ in 0..<2 {
      XCTAssertTrue(
        view.tryToPerform(#selector(TerminalMenuActions.increaseTerminalFontSize(_:)), with: nil))
    }
    XCTAssertLessThan(session.gridSize.columns, columns)
    XCTAssertTrue(
      view.tryToPerform(#selector(TerminalMenuActions.resetTerminalFontSize(_:)), with: nil))
    XCTAssertEqual(session.gridSize.columns, columns)

    XCTAssertTrue(
      view.tryToPerform(#selector(TerminalMenuActions.clearTerminalScreen(_:)), with: nil))
    try await waitUntil("the cleared screen") { !self.screen(session).contains("M:42:") }
  }

  // MARK: Tabs and program mode

  /// Catches a second session that shares the first one's tty, which tabs must never do. Two shells
  /// report different terminal devices. A foreground `cat` in the first makes only the first read
  /// as running, since the query is per session.
  func testTwoSessionsAreIndependentTerminals() async throws {
    let first = try startShell()
    let second = try startShell()
    try await waitUntil("two idle prompts") {
      !first.isRunningSomething && !second.isRunningSomething
    }

    try run("echo \"Y:$(tty):\"", in: first)
    try run("echo \"Y:$(tty):\"", in: second)

    let pattern = #"Y:(/dev/ttys\d+):"#
    try await waitUntil("both devices") {
      self.firstMatch(pattern, in: self.screen(first)) != nil
        && self.firstMatch(pattern, in: self.screen(second)) != nil
    }

    let one = try XCTUnwrap(firstMatch(pattern, in: screen(first)))
    let two = try XCTUnwrap(firstMatch(pattern, in: screen(second)))
    XCTAssertNotEqual(one, two)

    try run("cat", in: first)
    try await waitUntil("cat to run in the first session") { first.isRunningSomething }

    try run("echo \"Z:$((6*7)):\"", in: second)
    try await waitUntil("the second session's own command to finish") {
      self.screen(second).contains("Z:42:") && !second.isRunningSomething
    }
    XCTAssertTrue(first.isRunningSomething, "the first session stopped reading as running")
  }

  private func firstMatch(_ pattern: String, in text: String) -> String? {
    guard let expression = try? NSRegularExpression(pattern: pattern),
      let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
      match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text)
    else { return nil }

    return String(text[range])
  }

  /// Catches program mode that runs a shell instead of the program, or that rewrites its
  /// arguments. Also catches a pane that waits for a key after its program ends. The program
  /// prints its arguments, which hold a space, an apostrophe, a semicolon, a glob, and a variable
  /// name. None of them may be interpreted. The program reads a line, so it is running until
  /// Return. Once it ends, the exit event arrives with no further key, and libghostty's own
  /// "Press any key" text never appears.
  func testProgramRunsWithItsArgumentsIntactAndEndsWithoutAKey() async throws {
    let session = try startProgram([
      "/bin/sh", "-c", #"printf 'A:%s:%s:%s:\n' "$1" "$2" "$3"; read x"#, "sh",
      "two words", "it's;*", "$HOME",
    ])
    var exited = false
    session.onEvent = { event in
      if case .exited = event { exited = true }
    }

    try await waitUntil("the arguments") {
      self.screen(session).contains("A:two words:it's;*:$HOME:")
    }
    XCTAssertTrue(session.isRunningSomething, "a program waiting for input reads as idle")

    try press(session, keyCode: 0x24, characters: "\r")
    try await waitUntil("the exit event") { exited }

    XCTAssertFalse(self.screen(session).contains("Press any key"), self.screen(session))
  }

  /// Catches a program that ends at once leaving the pane open. libghostty treats a command that
  /// ends within 250 ms of launch as failed, and waits for a key under its own error text. The
  /// exit event arrives anyway, and the text never appears.
  func testAProgramThatEndsAtOnceEndsWithoutAKey() async throws {
    let session = try startProgram(["/usr/bin/true"])
    var exited = false
    session.onEvent = { event in
      if case .exited = event { exited = true }
    }

    try await waitUntil("the exit event") { exited }

    XCTAssertFalse(self.screen(session).contains("Press any key"), self.screen(session))
  }

  /// Catches a program launch that loses Ghostty's TERM, or an ssh launch that keeps it. A plain
  /// program sees xterm-ghostty. An ssh program, by name or by path, hands xterm-256color to the
  /// process that ssh starts. The probe is ssh's ProxyCommand, which runs locally with ssh's own
  /// environment, so no remote host is needed. A real host without the terminfo entry is not
  /// reachable from here.
  func testProgramModeKeepsGhosttyTermExceptForSsh() async throws {
    let plain = try startProgram(["/bin/sh", "-c", #"echo "T:$TERM:"; read x"#])
    try await waitUntil("the plain program's TERM") {
      self.screen(plain).contains("T:xterm-ghostty:")
    }

    // ssh runs the proxy command as `exec <command>`, so only the echo runs and ssh then fails
    // within 250 ms. libghostty adds an error screen below the output, which keeps the echo line.
    let probe = #"ProxyCommand=echo "PT:$TERM:" >&2"#

    for ssh in ["ssh", "/usr/bin/ssh"] {
      let session = try startProgram(
        [ssh, "-F", "/dev/null", "-o", "BatchMode=yes", "-o", probe, "nowhere"])

      try await waitUntil("the TERM that \(ssh) passes on") {
        self.screen(session).contains("PT:xterm-256color:")
      }
      XCTAssertFalse(screen(session).contains("PT:xterm-ghostty:"), ssh)
    }
  }

  /// Catches a shell that inherits noise or another Ghostty's resources, and one that reports
  /// libghostty's name. The test process starts with `MAKEFLAGS` set, runs the startup scrub, and
  /// then inherits a `GHOSTTY_RESOURCES_DIR` that points nowhere. The shell sees no `MAKEFLAGS`,
  /// the engine's own resources directory, and `TERM_PROGRAM=uniterm` with uniterm's version. The
  /// harness cannot run the app's `main`, so it calls the same scrub function that `main` calls.
  func testShellSeesTheScrubbedEnvironmentAndUnitermsIdentity() async throws {
    setenv("MAKEFLAGS", "-j8", 1)
    _ = InheritedEnvironment.scrubProcess()
    setenv("GHOSTTY_RESOURCES_DIR", "/nonexistent/other-ghostty", 1)

    engine = try GhosttyTerminalEngine(
      configStore: TerminalConfigStore(directory: sandbox.appending(path: "config-env")),
      resourcesDirectory: resources, helperDirectory: helper, palette: .latte)

    let session = try startShell()
    try await waitUntil("an idle prompt") { !session.isRunningSomething }

    let version = TerminalIdentity.bundleVersion
    try run(
      #"echo "TP:$TERM_PROGRAM:$TERM_PROGRAM_VERSION:"; echo "MF:${MAKEFLAGS-unset}:"; "#
        + #"[ "$GHOSTTY_RESOURCES_DIR" = '\#(resources.path)' ] && echo "RD:$((6*7)):""#,
      in: session)

    try await waitUntil("the environment report") {
      let text = self.screen(session)
      return text.contains("TP:uniterm:\(version):") && text.contains("MF:unset:")
        && text.contains("RD:42:")
    }
  }

  /// Catches a wrong claim about program launches. libghostty picks shell integration from the
  /// first word of the command. uniterm single-quotes every word, so the word never reads as
  /// `zsh` and integration stays off, whether the program is given by name or by path. A swapped
  /// `ZDOTDIR` would show that integration reached a program the user typed.
  func testAProgramLaunchOfZshGetsNoShellIntegration() async throws {
    for command in [["/bin/zsh", "-f"], ["zsh", "-f"]] {
      let session = try startProgram(command)

      try run(
        #"case "$ZDOTDIR" in *shell-integration*) echo "ZI:$((6*7)):yes";; *) echo "ZI:$((6*7)):no";; esac"#,
        in: session)

      try await waitUntil("the ZDOTDIR report of \(command[0])") {
        self.screen(session).contains("ZI:42:")
      }
      XCTAssertTrue(screen(session).contains("ZI:42:no"), "\(command): integration applied")
    }
  }

  /// Catches a backend patch that reports no child, or reports some other process, such as the
  /// pty's foreground group. The event names a direct child of this process, and that child is
  /// `login`, the session root a shell runs under.
  func testProcessStartedEventReportsTheDirectChild() async throws {
    try await assertReportsLogin(try startShell())
  }

  /// Catches the same for program mode, where libghostty spawns `login` for the program too.
  func testProcessStartedEventReportsTheDirectChildInProgramMode() async throws {
    try await assertReportsLogin(try startProgram(["/bin/sleep", "30"]))
  }

  /// Catches a closed session's queued exit reaching the session that reuses its address.
  ///
  /// libghostty queues each surface's messages for the main thread. The allocator often gives a
  /// freed surface's address to the next surface, as when a REPL restarts. A stale exit would end
  /// the new session's REPL, and libghostty would close it on the next key press.
  ///
  /// The main thread does not yield until the second session exists, so libghostty cannot drain
  /// the first session's exit before then. That exit is queued ahead of the second session's
  /// start, so it has had its turn once the start arrives.
  ///
  /// A pair whose second surface lands at another address proves nothing. The test makes another
  /// pair, and skips only when none of five pairs reuses an address.
  func testAClosedSessionsQueuedExitNeverReachesTheSessionThatReusesItsAddress() async throws {
    var reused: (any TerminalSession)?

    for _ in 0..<5 {
      let second = try startSecondAfterAQueuedExit()

      if second.reusedAddress {
        reused = second.session

        break
      }

      second.session.close()
    }

    guard let second = reused else {
      throw XCTSkip("no second surface reused the first's address, so nothing was proved")
    }

    var events: [String] = []

    second.onEvent = { event in
      switch event {
      case .exited: events.append("exited")
      case .processStarted: events.append("started")
      default: break
      }
    }

    try await waitUntil("the second session's start") { events.contains("started") }

    XCTAssertEqual(events, ["started"], "the second session got the first session's exit")
  }

  /// Starts a session whose program ends at once, waits on this thread until libghostty has reaped
  /// its child, closes it, and starts a second session. Nothing yields the main thread meanwhile.
  private func startSecondAfterAQueuedExit() throws -> (
    session: any TerminalSession, reusedAddress: Bool
  ) {
    let before = Set(children(of: getpid()))
    let first = try startProgram(["/usr/bin/true"])
    let deadline = ContinuousClock.now + .seconds(10)
    var login: pid_t?

    // libghostty reaps its child on its IO thread and queues the exit right after. Once the child
    // is gone, freeing the surface joins that thread, so the exit is in the queue on return.
    while ContinuousClock.now < deadline {
      let current = Set(children(of: getpid())).subtracting(before)

      if login == nil { login = current.first }

      if let login, !current.contains(login) { break }

      sched_yield()
    }

    let reaped = try XCTUnwrap(login, "the first session never started a child")

    XCTAssertFalse(children(of: getpid()).contains(reaped), "the first session's child never ended")

    let freed = try XCTUnwrap(Self.address(of: first), "the first session has no surface")

    first.close()

    let second = try startProgram(["/bin/sleep", "30"])

    return (second, Self.address(of: second) == freed)
  }

  /// The libghostty surface a session draws, read by reflection, so the view exports nothing for
  /// the test.
  private static func address(of session: any TerminalSession) -> UnsafeMutableRawPointer? {
    Mirror(reflecting: session).children.first { $0.label == "surface" }
      .flatMap { $0.value as? UnsafeMutableRawPointer }
  }

  /// Waits for the session's identity event, then checks the PID it names: a direct child of
  /// this process, running `login`, and started at the second the event reports.
  private func assertReportsLogin(
    _ session: any TerminalSession, file: StaticString = #filePath, line: UInt = #line
  ) async throws {
    var reported: TerminalProcessIdentity?

    session.onEvent = { event in
      if case .processStarted(let identity) = event { reported = identity }
    }

    try await waitUntil("the processStarted event") { reported != nil }

    let identity = try XCTUnwrap(reported, file: file, line: line)

    XCTAssertTrue(
      children(of: getpid()).contains(identity.pid), "the PID is not a direct child", file: file,
      line: line)

    // The child is setuid-root login, which proc_pidinfo refuses for this user, so read it with
    // sysctl.
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, identity.pid]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.size

    XCTAssertEqual(
      sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0), 0, "no process info", file: file,
      line: line)

    let command = withUnsafeBytes(of: info.kp_proc.p_comm) { bytes in
      String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }

    XCTAssertEqual(command, "login", "the direct child is not login", file: file, line: line)
    XCTAssertEqual(
      Int(info.kp_proc.p_starttime.tv_sec), identity.started, "the start time is not the child's",
      file: file, line: line)
  }
}
