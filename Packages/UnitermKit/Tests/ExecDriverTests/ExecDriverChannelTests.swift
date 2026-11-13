import AppletFixtures
import AppletKit
import Darwin
import ExecTestSupport
import Foundation
import StatusKit
import XCTest

@testable import ExecDriver

/// Runs a real driver process against a real hosted fixture, through the real pipes, wire, and
/// shared dispatch. The driver is a perl script with one mode for each behavior, good or bad.
///
/// These prove what crosses the process boundary: hellos, commands, events, stderr, exits, and
/// every bound. They cannot prove the window's chrome or its launch approval. The window's tests
/// prove those.
@MainActor
final class ExecDriverChannelTests: XCTestCase {
  private var center: StatusCenter!
  private var applet: SlidesFixture!
  private var dispatcher: ControlDispatcher!
  private var ended: [ExecDriverChannel.End] = []
  private var channels: [ExecDriverChannel] = []
  private var scratch: URL!

  override func setUp() async throws {
    center = StatusCenter()
    applet = SlidesFixture()
    dispatcher = ControlDispatcher()
    ended = []
    scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
      "exec-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
  }

  override func tearDown() async throws {
    for channel in channels { channel.close() }

    channels = []
    try? FileManager.default.removeItem(at: scratch)
  }

  private func start(
    _ mode: String, type: String = SlidesFixture.typeID, schema: Int = 1, _ rest: [String] = [],
    directory: String? = nil, keys: [String] = [], values: [String: String] = [:],
    killGrace: DispatchTimeInterval = .seconds(2)
  ) throws -> ExecDriverChannel {
    let declaration = try ExecDeclaration(
      arguments: ExecTestDriver.arguments(mode, type: type, schema: schema, rest),
      directory: directory, environmentKeys: keys)
    let environment = try XCTUnwrap(ExecEnvironment.current())
    let launch = try ExecLaunch(
      declaration: declaration, environment: values, home: environment.home)

    let channel = ExecDriverChannel(
      launch: launch, environment: environment, applet: applet, dispatcher: dispatcher,
      authority: { nil }, producer: center.issueProducer(kind: .applet, name: "driver"),
      killGrace: killGrace, onEnd: { [weak self] end in self?.ended.append(end) })

    channels.append(channel)
    try channel.start()

    return channel
  }

  private func waitUntil(
    _ what: String, timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line,
    _ condition: () -> Bool
  ) async {
    let deadline = Date().addingTimeInterval(timeout)

    while !condition() {
      guard Date() < deadline else {
        XCTFail("timed out waiting until \(what)", file: file, line: line)
        return
      }

      try? await Task.sleep(for: .milliseconds(10))
    }
  }

  private func command(_ name: String, _ arguments: String) -> String {
    #"{"name":"\#(name)","arguments":\#(arguments)}"#
  }

  private var historyTexts: [String] { center.history.map(\.text) }

  /// Catches a driver whose commands never reach the applet, events that never reach the driver,
  /// or a reply that never comes back. The driver answers the user's Next with a show-slide.
  func testTheDriversStdoutDrivesTheAppletAndItsStdinGetsEvents() async throws {
    let channel = try start(
      "script",
      [
        command("set-deck", #"{"titles":["One","Two","Three"]}"#),
        command("show-slide", #"{"index":1}"#),
      ])

    await waitUntil("the second slide shows") { applet.index == 1 }

    XCTAssertEqual(channel.phase, .connected)
    XCTAssertEqual(applet.titles, ["One", "Two", "Three"])

    applet.button.performClick(nil)

    await waitUntil("the driver advances") { applet.index == 2 }
    await waitUntil("the driver logs the replies and events") {
      historyTexts.contains("got reply") && historyTexts.contains("got event advance-requested")
        && historyTexts.contains("got event slide-shown")
    }
  }

  /// Catches stderr that takes a turn on the status bar, that gets a level from its words, or a
  /// flood that the history keeps unbounded or that stalls the main thread.
  func testStderrIsBoundedInfoInTheHistoryOnly() async throws {
    _ = try start("stderr-flood")

    let started = Date()
    var turns = 0

    await waitUntil("the flood ends", timeout: 30) {
      turns += 1
      return historyTexts.contains("flood done")
    }

    XCTAssertGreaterThan(turns, 1, "the main thread got turns during the flood")
    XCTAssertLessThan(Date().timeIntervalSince(started), 30)
    XCTAssertNil(center.display, "stderr took a turn on the status bar")
    XCTAssertTrue(center.history.allSatisfy { $0.level == .info })
    XCTAssertLessThanOrEqual(center.history.count, StatusPolicy.standard.otherHistoryLimit)
    XCTAssertTrue(historyTexts.contains { $0.contains("did not fit and were dropped") })
  }

  /// Catches a driver exit that goes unreported, or one reported at a level guessed from text.
  func testAnExitIsATypedWarningAndEndsTheChannel() async throws {
    let channel = try start("exit", ["3"])

    await waitUntil("the driver exits") { !ended.isEmpty }

    XCTAssertEqual(ended, [.exited(3 << 8)])
    XCTAssertEqual(channel.phase, .ended(.exited(3 << 8)))
    XCTAssertEqual(center.display?.message.level, .warning)
    XCTAssertEqual(center.display?.message.text, "The driver exited with status 3.")
  }

  /// Catches a mismatch in either direction that lets a command run: a driver that names another
  /// protocol or schema version, one that refuses the app's hello, and one that sends a command
  /// before its hello. Each driver sends a set-deck that must never land.
  func testEveryHelloMismatchEndsTheChannelWithNoCommandRun() async throws {
    let cases: [(String, Int, [String], String)] = [
      ("hello-protocol", 1, ["1"], "exec protocol 1"),
      ("hello-protocol", 1, ["2"], "exec protocol 2"),
      ("hello-schema", 1, ["2"], "schema version 2"),
      ("refuse", 1, [], "needs exec protocol 9"),
      ("command-first", 1, [], "before its hello"),
      ("script", 1, [], "written for a fixture-chart"),
    ]

    for (mode, schema, rest, needle) in cases {
      ended = []
      applet = SlidesFixture()

      let type = mode == "script" ? ChartFixture.typeID : SlidesFixture.typeID
      _ = try start(mode, type: type, schema: schema, rest)

      await waitUntil("\(mode) ends") { !ended.isEmpty }
      try? await Task.sleep(for: .milliseconds(200))

      XCTAssertEqual(applet.titles, [], "\(mode) ran a command")
      XCTAssertTrue(
        ended.first?.description.contains(needle) == true, "\(mode): \(ended)")
      XCTAssertEqual(center.display?.message.level, .warning, mode)
    }
  }

  /// Catches a malformed line, a partial line at the end, or a line past the frame bound that
  /// leaves the channel open or that runs anything.
  func testBadFramesCloseTheChannelVisibly() async throws {
    let cases = [
      ("malformed", "not a message"), ("partial", "middle of a line"),
      ("long-line", "longer than"),
    ]

    for (mode, needle) in cases {
      ended = []
      _ = try start(mode)

      await waitUntil("\(mode) fails") { !ended.isEmpty }

      guard case .failed(let reason)? = ended.first else {
        XCTFail("\(mode) ended as \(ended)")
        continue
      }

      XCTAssertTrue(reason.contains(needle), "\(mode): \(reason)")
    }
  }

  /// Catches a flood of small commands from a driver that never reads its replies, growing a
  /// queue without bound or holding the main thread. It must fail visibly once a bound is passed.
  func testEndlessSmallFramesStayBoundedAndFail() async throws {
    _ = try start("flood")

    var turns = 0

    await waitUntil("the flood fails", timeout: 60) {
      turns += 1
      return !ended.isEmpty
    }

    XCTAssertGreaterThan(turns, 1)
    XCTAssertLessThanOrEqual(dispatcher.queuedCount, dispatcher.maximumQueued)

    guard case .failed(let reason)? = ended.first else {
      return XCTFail("the flood ended as \(ended)")
    }

    XCTAssertTrue(reason.contains("MiB"), reason)
  }

  /// Catches events to a driver that never reads stdin blocking the main thread, or piling up
  /// past the retained bound instead of failing.
  func testAStalledStdinFailsWithoutBlockingTheEmitter() async throws {
    let channel = try start("stall")

    await waitUntil("the hellos finish") { channel.isConnected }

    let started = Date()
    let title = String(repeating: "t", count: 200)

    for _ in 0..<40_000 where channel.isConnected {
      applet.events.emit("slide-shown", .object(["index": .number(1), "title": .string(title)]))
    }

    XCTAssertLessThan(Date().timeIntervalSince(started), 5, "emitting blocked the main thread")

    await waitUntil("the stall fails") { !ended.isEmpty }

    guard case .failed(let reason)? = ended.first else { return XCTFail("ended as \(ended)") }

    XCTAssertTrue(reason.contains("stopped reading its input"), reason)
  }

  /// Catches a close that waits for the child, or a child that outlives the close because it
  /// ignores SIGTERM.
  func testCloseReturnsAtOnceAndEndsAChildThatIgnoresTerm() async throws {
    let channel = try start("ignore-term", killGrace: .milliseconds(300))

    await waitUntil("the hellos finish") { channel.isConnected }

    let pid = try XCTUnwrap(channel.pid)
    let started = Date()

    applet.close()

    XCTAssertLessThan(Date().timeIntervalSince(started), 0.1, "close waited for the child")
    XCTAssertEqual(ended, [.closed])
    XCTAssertNil(center.display, "a close the user made is not reported")

    await waitUntil("the child is gone") { kill(pid, 0) != 0 }
  }

  /// Catches a close whose SIGKILL never reaches the driver's group because the leader exited on
  /// SIGTERM first. A background child that ignores SIGTERM would then outlive the driver and
  /// hold its stdout open, so the reader threads and pipes would leak too.
  func testCloseEndsABackgroundChildThatIgnoresTerm() async throws {
    let file = scratch.appendingPathComponent("grandchild")
    let channel = try start("grandchild", [file.path], killGrace: .milliseconds(300))

    await waitUntil("the driver connects and names its child") {
      channel.isConnected && FileManager.default.fileExists(atPath: file.path)
    }

    let text = try String(contentsOf: file, encoding: .utf8)
    let child = try XCTUnwrap(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))

    XCTAssertEqual(kill(child, 0), 0, "the background child is not running")

    channel.close()

    await waitUntil("the background child is gone", timeout: 5) { kill(child, 0) != 0 }

    if kill(child, 0) == 0 { kill(child, SIGKILL) }
  }

  /// Catches a channel whose applet closed before it started, and that spawns a child anyway or
  /// never reports its end, so the pane would show a driver running that nothing reaps.
  func testAChannelForAClosedAppletSpawnsNothingAndEnds() throws {
    applet.close()

    let channel = try start("silent")

    XCTAssertEqual(ended, [.closed])
    XCTAssertEqual(channel.phase, .ended(.closed))
    XCTAssertNil(channel.pid, "a child was spawned for an applet that had closed")
  }

  /// Catches a child that inherits uniterm's environment or directory, or misses a declared value.
  func testTheChildGetsOnlyTheDeclaredEnvironmentAndDirectory() async throws {
    let declared = scratch.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: declared, withIntermediateDirectories: true)

    for directory in [declared.path, nil] {
      let output = scratch.appendingPathComponent("env-\(directory == nil ? "home" : "dir")")

      let channel = try start(
        "env", [output.path], directory: directory, keys: ["SYNTHETIC_TOKEN"],
        values: ["SYNTHETIC_TOKEN": "value"])

      await waitUntil("the driver writes its environment") {
        FileManager.default.fileExists(atPath: output.path) && channel.isConnected
      }

      try? await Task.sleep(for: .milliseconds(200))

      let lines = try String(contentsOf: output, encoding: .utf8).split(separator: "\n")
      let fields = Dictionary(
        uniqueKeysWithValues: lines.map { line in
          let parts = line.split(separator: "=", maxSplits: 1)
          return (String(parts[0]), parts.count > 1 ? String(parts[1]) : "")
        })
      let environment = try XCTUnwrap(ExecEnvironment.current())
      let expected = directory ?? environment.home

      XCTAssertEqual(
        Set(fields.keys), ["cwd", "HOME", "USER", "LOGNAME", "TMPDIR", "PATH", "SYNTHETIC_TOKEN"])
      XCTAssertEqual(
        URL(fileURLWithPath: fields["cwd"] ?? "").resolvingSymlinksInPath().path,
        URL(fileURLWithPath: expected).resolvingSymlinksInPath().path)
      XCTAssertEqual(fields["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
      XCTAssertEqual(fields["SYNTHETIC_TOKEN"], "value")
      XCTAssertEqual(fields["HOME"], environment.home)

      channel.close()
    }
  }
}
