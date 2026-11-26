import Darwin
import ProcessInspection
import XCTest

/// What the process readers report for a live process, a missing one, and one that has exited but
/// was not yet collected. Every liveness check in the script host rests on these answers.
final class ProcessInspectionTests: XCTestCase {
  /// Catches a missing process read as one that started at second zero. For a PID with no
  /// process, sysctl succeeds and returns an empty record, which must read as no process.
  func testAProcessThatDoesNotExistHasNoStartTimeAndNoParent() {
    let missing: pid_t = 999_999

    XCTAssertNil(ProcessInspection.startTime(of: missing))
    XCTAssertNil(ProcessInspection.startTimeMicroseconds(of: missing))
    XCTAssertNil(ProcessInspection.parent(of: missing))
    XCTAssertFalse(ProcessInspection.isRunning(pid: missing, started: 0))
  }

  /// Catches a zombie read as running. A peer that exited keeps a kernel record until its parent
  /// collects it, and a child that inherited its socket would otherwise keep its authority for that
  /// long. The child here has exited and is left uncollected on purpose.
  func testAnExitedProcessThatIsNotYetCollectedIsNotRunning() throws {
    var pid: pid_t = 0
    let path = "/usr/bin/true"
    var argv: [UnsafeMutablePointer<CChar>?] = [strdup(path), nil]

    defer {
      for word in argv { free(word) }
    }

    XCTAssertEqual(posix_spawn(&pid, path, nil, nil, &argv, environ), 0)

    let started = ProcessInspection.startTime(of: pid)
    var exited = siginfo_t()

    XCTAssertEqual(waitid(P_PID, id_t(pid), &exited, WEXITED | WNOWAIT), 0)

    defer {
      var status: Int32 = 0
      waitpid(pid, &status, 0)
    }

    XCTAssertEqual(kill(pid, 0), 0, "the child was collected before the check")
    XCTAssertNil(ProcessInspection.startTime(of: pid), "a zombie reported a start time")
    XCTAssertNil(ProcessInspection.startTimeMicroseconds(of: pid), "a zombie reported a start")
    XCTAssertNil(ProcessInspection.parent(of: pid), "a zombie reported a parent")
    XCTAssertFalse(ProcessInspection.isRunning(pid: pid, started: started ?? 0))
  }

  /// Catches a reader that cannot see a live process. The test process has a start time, a
  /// parent, and reads as running under that start time.
  func testTheTestProcessHasAStartTimeAndAParent() throws {
    let started = try XCTUnwrap(ProcessInspection.startTime(of: getpid()))
    let microseconds = try XCTUnwrap(ProcessInspection.startTimeMicroseconds(of: getpid()))

    XCTAssertEqual(microseconds / 1_000_000, started, "the two readers disagree on the second")
    XCTAssertEqual(ProcessInspection.parent(of: getpid())?.pid, getppid())
    XCTAssertTrue(ProcessInspection.isRunning(pid: getpid(), started: started))
    XCTAssertFalse(ProcessInspection.isRunning(pid: getpid(), started: started - 1))
  }

  /// Catches a child list that misses a live child, lists a process that is not one, or reads a
  /// count of PIDs as a count of bytes. The child is a real `sleep`.
  func testChildrenAndNameOfARealChild() throws {
    var pid: pid_t = 0
    let path = "/bin/sleep"
    var argv: [UnsafeMutablePointer<CChar>?] = [strdup(path), strdup("30"), nil]

    defer {
      for word in argv { free(word) }
    }

    XCTAssertEqual(posix_spawn(&pid, path, nil, nil, &argv, environ), 0)

    defer {
      kill(pid, SIGKILL)

      var status: Int32 = 0
      waitpid(pid, &status, 0)
    }

    XCTAssertTrue(ProcessInspection.children(of: getpid()).contains(pid))
    XCTAssertEqual(ProcessInspection.name(of: pid), "sleep")
    XCTAssertEqual(ProcessInspection.children(of: pid), [])
  }

  /// Catches a name or a child list for a PID with no process.
  func testAProcessThatDoesNotExistHasNoNameAndNoChildren() {
    XCTAssertNil(ProcessInspection.name(of: 999_999))
    XCTAssertEqual(ProcessInspection.children(of: 999_999), [])
  }
}
