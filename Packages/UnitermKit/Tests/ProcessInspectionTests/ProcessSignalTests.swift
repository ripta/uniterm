import Darwin
import XCTest

@testable import ProcessInspection

/// A child the test spawns and reaps itself. A gated child holds its standard input on a pipe, so
/// a child that reads before it acts waits until the test opens the gate.
private final class Child {
  let pid: pid_t
  private var gate: Int32
  private var reaped = false

  init(_ arguments: [String], gated: Bool = false) throws {
    var ends: [Int32] = [-1, -1]

    if gated {
      guard pipe(&ends) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }

    var actions: posix_spawn_file_actions_t?

    posix_spawn_file_actions_init(&actions)

    defer { posix_spawn_file_actions_destroy(&actions) }

    if gated {
      posix_spawn_file_actions_adddup2(&actions, ends[0], STDIN_FILENO)
      posix_spawn_file_actions_addclose(&actions, ends[0])
      posix_spawn_file_actions_addclose(&actions, ends[1])
    }

    let argv = arguments.map { strdup($0) } + [nil]

    defer {
      for word in argv { free(word) }
    }

    var pid: pid_t = 0
    let status = posix_spawn(&pid, arguments[0], &actions, nil, argv, environ)

    if gated { close(ends[0]) }

    guard status == 0 else {
      if gated { close(ends[1]) }

      throw POSIXError(.init(rawValue: status) ?? .EIO)
    }

    self.pid = pid
    gate = gated ? ends[1] : -1
  }

  /// A child that waits for the gate, then execs `/bin/sleep`.
  static func execsOnOpen() throws -> Child {
    try Child(["/bin/sh", "-c", "read line; exec /bin/sleep 30"], gated: true)
  }

  static func sleeping() throws -> Child {
    try Child(["/bin/sleep", "30"])
  }

  func open() {
    guard gate >= 0 else { return }

    _ = "\n".withCString { write(gate, $0, 1) }
    close(gate)
    gate = -1
  }

  /// True while the child runs and has not exited. A zombie reads false.
  var isAlive: Bool { !reaped && ProcessInspection.startTimeMicroseconds(of: pid) != nil }

  /// Waits for the child and returns the signal that ended it, or nil for an exit.
  @discardableResult
  func reap() -> Int32? {
    var status: Int32 = 0

    while waitpid(pid, &status, 0) < 0 && errno == EINTR {}

    reaped = true

    let signal = status & 0x7F

    return signal == 0 ? nil : signal
  }

  /// Waits until the child's executable is `path`, for up to ten seconds.
  func waitForImage(_ path: String) -> Bool {
    let deadline = Date().addingTimeInterval(10)

    while Date() < deadline {
      if ProcessInspection.executablePath(of: pid) == path { return true }

      usleep(1_000)
    }

    return false
  }

  /// The child signals before its own reap, so the pid is still the child's.
  func end() {
    guard !reaped else { return }

    open()
    kill(pid, SIGKILL)
    reap()
  }

  deinit { end() }
}

/// A start time that differs from `started` by one microsecond and still falls in the same second,
/// so a check that compares whole seconds would take it as a match.
private func oneMicrosecondOff(_ started: Int) -> Int {
  started % 1_000_000 < 999_999 ? started + 1 : started - 1
}

/// The guarded signal against real children. Each test pins the fix, not the bug, since no test
/// can force the system to hand a freed pid to another process inside the call.
final class ProcessSignalTests: XCTestCase {
  /// Catches a signal to a pid the call must never touch. Pid 0 is the caller's group, 1 is
  /// launchd, and the caller's own pid ends the caller. Each gets its real start time, so only the
  /// refusal stops it. SIGCONT keeps a missing refusal harmless, since nothing here is stopped.
  func testPidsAtOrBelowOneAndTheCallersOwnAreRefused() {
    for pid in [0, 1, getpid()] {
      let started = ProcessInspection.startTimeMicroseconds(of: pid) ?? 0

      XCTAssertEqual(
        ProcessInspection.signal(SIGCONT, pid: pid, startedMicroseconds: started), .refused,
        "pid \(pid)")
    }
  }

  /// Catches a live child that the token path cannot reach. A child of the caller gives a token,
  /// so it ends by the token and not by the pid.
  func testALiveChildEndsByTheToken() throws {
    let child = try Child.sleeping()
    let started = try XCTUnwrap(ProcessInspection.startTimeMicroseconds(of: child.pid))

    XCTAssertEqual(
      ProcessInspection.signal(SIGKILL, pid: child.pid, startedMicroseconds: started), .byToken)
    XCTAssertEqual(child.reap(), SIGKILL)
  }

  /// Catches a start time compared at a coarser precision than recorded. A start one microsecond
  /// off, in the same second, names another process, so the child is not signalled.
  func testAStartTimeOneMicrosecondOffLeavesTheChildAlive() throws {
    let child = try Child.sleeping()
    let started = try XCTUnwrap(ProcessInspection.startTimeMicroseconds(of: child.pid))

    XCTAssertEqual(
      ProcessInspection.signal(
        SIGKILL, pid: child.pid, startedMicroseconds: oneMicrosecondOff(started)), .gone)
    XCTAssertTrue(child.isAlive)
  }

  /// Catches a reaped child read as live. Its pid names nothing now, so the call reports it gone.
  func testAReapedChildIsGone() throws {
    let child = try Child(["/bin/sh", "-c", "read line"], gated: true)
    let started = try XCTUnwrap(ProcessInspection.startTimeMicroseconds(of: child.pid))

    child.open()
    XCTAssertNil(child.reap())

    XCTAssertEqual(
      ProcessInspection.signal(SIGKILL, pid: child.pid, startedMicroseconds: started), .gone)
  }

  /// Catches a zombie that takes the pid path. A zombie gives no token, and the start-time reader
  /// rejects it, so the call reports it gone instead of signalling its pid.
  func testAnExitedChildThatIsNotYetCollectedIsGone() throws {
    let child = try Child(["/bin/sh", "-c", "read line"], gated: true)
    let started = try XCTUnwrap(ProcessInspection.startTimeMicroseconds(of: child.pid))
    var exited = siginfo_t()

    child.open()

    XCTAssertEqual(waitid(P_PID, id_t(child.pid), &exited, WEXITED | WNOWAIT), 0)
    XCTAssertEqual(kill(child.pid, 0), 0, "the child was collected before the check")
    XCTAssertEqual(
      ProcessInspection.signal(SIGKILL, pid: child.pid, startedMicroseconds: started), .gone)
    XCTAssertNil(child.reap(), "the zombie was signalled")
  }

  /// Catches an exec read as another process. The start time recorded before the exec still
  /// matches after it, and a token read after the exec reaches the new image.
  func testAChildThatExecdEndsByTheTokenUnderItsEarlierStartTime() throws {
    let child = try Child.execsOnOpen()
    let started = try XCTUnwrap(ProcessInspection.startTimeMicroseconds(of: child.pid))

    child.open()

    XCTAssertTrue(child.waitForImage("/bin/sleep"), "the child never exec'd")
    XCTAssertEqual(
      ProcessInspection.signal(SIGKILL, pid: child.pid, startedMicroseconds: started), .byToken)
    XCTAssertEqual(child.reap(), SIGKILL)
  }

  /// Catches a token signal that ignores the pid version. A token one version off names a process
  /// that no longer exists, so the kernel answers ESRCH, as a returned errno, and the child lives.
  ///
  /// First, a SIGCONT through the live token shows the send itself works. A sleeping child ignores
  /// it.
  func testATokenOnePidVersionOffFindsNoProcess() throws {
    let child = try Child.sleeping()
    var token = try XCTUnwrap(ProcessInspection.auditToken(of: child.pid))

    XCTAssertEqual(ProcessInspection.send(SIGCONT, to: token), 0, "the live token reached nothing")

    token.val.7 &+= 1

    XCTAssertEqual(ProcessInspection.send(SIGKILL, to: token), ESRCH)
    XCTAssertTrue(child.isAlive)
  }

  /// Catches a token read that keeps its task name port. Each read takes a send right, so a leak
  /// leaves a second reference on the port after the test takes its own.
  func testTheTokenReadReleasesItsTaskNamePort() throws {
    let child = try Child.sleeping()

    XCTAssertNotNil(ProcessInspection.auditToken(of: child.pid))

    var port = mach_port_name_t(MACH_PORT_NULL)

    XCTAssertEqual(task_name_for_pid(mach_task_self_, child.pid, &port), KERN_SUCCESS)

    defer { mach_port_deallocate(mach_task_self_, port) }

    var references: mach_port_urefs_t = 0

    XCTAssertEqual(
      mach_port_get_refs(mach_task_self_, port, MACH_PORT_RIGHT_SEND, &references), KERN_SUCCESS)
    XCTAssertEqual(references, 1, "the token read left its port reference behind")
  }

  // MARK: Retries

  /// Catches a stale token that ends the call. The first token was read before the child exec'd,
  /// so its signal gets ESRCH. The retry reads a fresh token and ends the exec'd process.
  func testAStaleTokenIsRetriedWithAFreshOne() throws {
    let child = try Child.execsOnOpen()
    let started = try XCTUnwrap(ProcessInspection.startTimeMicroseconds(of: child.pid))
    let stale = try XCTUnwrap(ProcessInspection.auditToken(of: child.pid))

    child.open()

    XCTAssertTrue(child.waitForImage("/bin/sleep"), "the child never exec'd")
    XCTAssertEqual(
      ProcessInspection.send(SIGCONT, to: stale), ESRCH, "the exec left the token live")

    var reads = 0
    let result = ProcessInspection.signal(
      SIGKILL, pid: child.pid, startedMicroseconds: started,
      readToken: { pid in
        reads += 1

        return reads == 1 ? stale : ProcessInspection.auditToken(of: pid)
      })

    XCTAssertEqual(result, .byToken)
    XCTAssertEqual(reads, 2)
    XCTAssertEqual(child.reap(), SIGKILL)
  }

  /// Catches a pid fallback after ESRCH. A token signal that found no process means the pid may
  /// name another one, so a retry that reads no token sends nothing and the child lives.
  func testARetryThatReadsNoTokenSendsNothing() throws {
    let child = try Child.execsOnOpen()
    let started = try XCTUnwrap(ProcessInspection.startTimeMicroseconds(of: child.pid))
    let stale = try XCTUnwrap(ProcessInspection.auditToken(of: child.pid))

    child.open()

    XCTAssertTrue(child.waitForImage("/bin/sleep"), "the child never exec'd")

    var reads = 0
    let result = ProcessInspection.signal(
      SIGKILL, pid: child.pid, startedMicroseconds: started,
      readToken: { _ in
        reads += 1

        return reads == 1 ? stale : nil
      })

    XCTAssertEqual(result, .unreached)
    XCTAssertTrue(child.isAlive)
  }

  /// Catches a retry that reports unreached for a process that ended. The child ends between the
  /// two reads, so its start time no longer matches and the call reports it gone.
  func testARetryAfterTheProcessEndedReportsGone() throws {
    let child = try Child.execsOnOpen()
    let started = try XCTUnwrap(ProcessInspection.startTimeMicroseconds(of: child.pid))
    let stale = try XCTUnwrap(ProcessInspection.auditToken(of: child.pid))

    child.open()

    XCTAssertTrue(child.waitForImage("/bin/sleep"), "the child never exec'd")

    var reads = 0
    let result = ProcessInspection.signal(
      SIGKILL, pid: child.pid, startedMicroseconds: started,
      readToken: { _ in
        reads += 1

        guard reads == 1 else {
          child.end()
          return nil
        }

        return stale
      })

    XCTAssertEqual(result, .gone)
    XCTAssertEqual(reads, 2)
  }

  /// Catches a call that gives up too soon, retries without bound, or reports gone for a process
  /// that still runs. Three stale tokens in a row end the call as unreached, and the child lives.
  func testThreeStaleTokensReportUnreached() throws {
    let child = try Child.execsOnOpen()
    let started = try XCTUnwrap(ProcessInspection.startTimeMicroseconds(of: child.pid))
    let stale = try XCTUnwrap(ProcessInspection.auditToken(of: child.pid))

    child.open()

    XCTAssertTrue(child.waitForImage("/bin/sleep"), "the child never exec'd")

    var reads = 0
    let result = ProcessInspection.signal(
      SIGKILL, pid: child.pid, startedMicroseconds: started,
      readToken: { _ in
        reads += 1

        return stale
      })

    XCTAssertEqual(result, .unreached)
    XCTAssertEqual(reads, 3)
    XCTAssertTrue(child.isAlive)
  }

  /// Catches a pid path that skips the start-time match, or one that never signals. With no token
  /// at all, a matching start time ends the child by its pid, and a start one microsecond off
  /// leaves it alone.
  func testWithNoTokenTheStartTimeDecidesThePidSignal() throws {
    let child = try Child.sleeping()
    let started = try XCTUnwrap(ProcessInspection.startTimeMicroseconds(of: child.pid))

    XCTAssertEqual(
      ProcessInspection.signal(
        SIGKILL, pid: child.pid, startedMicroseconds: oneMicrosecondOff(started),
        readToken: { _ in nil }), .gone)
    XCTAssertTrue(child.isAlive)
    XCTAssertEqual(
      ProcessInspection.signal(
        SIGKILL, pid: child.pid, startedMicroseconds: started, readToken: { _ in nil }), .byPid)
    XCTAssertEqual(child.reap(), SIGKILL)
  }
}
