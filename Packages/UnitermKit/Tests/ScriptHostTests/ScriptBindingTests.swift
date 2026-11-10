import Darwin
import Foundation
import PaneModel
import ProcessInspection
import ScriptTestSupport
import ScriptWire
import StatusKit
import XCTest

@testable import ScriptHost

/// Tests for connection binding and ancestry validation. Covers bound descendant calls, unbound
/// refusal, dead peer detection, PID reuse, and session root lifecycle.
@MainActor
final class ScriptBindingTests: XCTestCase {
  private var directory: URL!
  private var center: StatusCenter!
  private var host: ScriptHost!
  private var windows: FakeWindowAPI!

  override func setUp() async throws {
    directory = try ScriptFixtures.makeSocketDirectory()
    center = StatusCenter()
    windows = FakeWindowAPI()

    let center = center!

    host = ScriptHost(
      listener: try ScriptListener.start(directory: directory),
      issueProducer: { center.issueProducer(kind: .script, name: $0) }, windows: windows)
    host.start()

    recordTestProcessAsSessionRoot(host)
  }

  override func tearDown() async throws {
    host.stop()
    try? FileManager.default.removeItem(at: directory)
  }

  /// A script descendant of a recorded session root has its calls answered.
  func testABoundDescendantCallSucceeds() async throws {
    let run = try await ScriptFixtures.run(
      socket: host.instanceAddress, script: ScriptFixtures.script("list-windows"))

    XCTAssertEqual(run.status, 0, run.standardError)
    XCTAssertFalse(
      run.standardError.contains("not running in a uniterm pane"),
      "bound descendant was refused")
  }

  /// A script not descendant of any recorded session root is refused for all calls except
  /// api-version.
  func testAnUnboundNonDescendantIsRefused() async throws {
    TestSessionRoot.remove(from: host)

    let run = try await ScriptFixtures.run(
      socket: host.instanceAddress, script: ScriptFixtures.script("list-windows"))

    XCTAssertEqual(run.status, 1)
    XCTAssertTrue(
      run.standardError.contains("not running in a uniterm pane"), run.standardError)
  }

  /// Catches a binding that outlives its peer. The root is the live test process, so only the
  /// peer's own exit can fail the check. The peer is a child that has exited and been collected.
  func testABindingFailsOnceItsPeerHasExited() throws {
    let child = Process()

    child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try child.run()

    let started = try XCTUnwrap(ProcessInspection.startTime(of: child.processIdentifier))

    child.waitUntilExit()

    let peer = ScriptPeer(uid: getuid(), pid: child.processIdentifier, token: nil)
    let (app, _) = try FramedSocket.pair()
    let connection = ScriptConnection(
      id: 1, peer: peer, peerStartTime: started, socket: app, onOverflow: { _ in })

    connection.bind(to: TestSessionRoot.identity, generation: 1)

    XCTAssertFalse(connection.validateBinding(registry: host.sessionRoots), "dead peer passed")
  }

  /// A PID that is reused for a different process is detected by start time mismatch.
  func testPIDReuseIsDetected() throws {
    let oldStartTime = 1000
    let currentPid = getpid()
    let testRoot = ProcessIdentity(pid: currentPid, started: oldStartTime)

    host.recordSessionRoot(testRoot, sessionGeneration: 1, window: 1, pane: NodeID(rawValue: 1))

    let peer = ScriptPeer(uid: getuid(), pid: currentPid, token: nil)
    let currentStartTime = ProcessInspection.startTime(of: currentPid) ?? 0
    let (app, _) = try FramedSocket.pair()
    let connection = ScriptConnection(
      id: 1, peer: peer, peerStartTime: currentStartTime, socket: app,
      onOverflow: { _ in })

    connection.bind(to: testRoot, generation: 1)

    let valid = connection.validateBinding(registry: host.sessionRoots)

    XCTAssertFalse(
      valid,
      "PID reuse not detected (start times: recorded=\(oldStartTime), current=\(currentStartTime))")
  }

  /// A session root that is removed from the registry causes bound connections to fail validation.
  func testClosedSourceTabRemovesSessionRoot() throws {
    let testRoot = TestSessionRoot.identity

    let peer = ScriptPeer(uid: getuid(), pid: getpid(), token: nil)
    let (app, _) = try FramedSocket.pair()
    let connection = ScriptConnection(
      id: 1, peer: peer, peerStartTime: testRoot.started, socket: app,
      onOverflow: { _ in })

    connection.bind(to: testRoot, generation: 1)

    XCTAssertTrue(
      connection.validateBinding(registry: host.sessionRoots), "binding invalid before removal")

    TestSessionRoot.remove(from: host)

    XCTAssertFalse(
      connection.validateBinding(registry: host.sessionRoots), "binding still valid after removal")
  }

  /// A session that is replaced (same PID but different generation) invalidates old connections.
  func testHelperReplacementInvalidatesOldGeneration() throws {
    let testRoot = TestSessionRoot.identity

    let peer = ScriptPeer(uid: getuid(), pid: getpid(), token: nil)
    let (app, _) = try FramedSocket.pair()
    let connection = ScriptConnection(
      id: 1, peer: peer, peerStartTime: testRoot.started, socket: app,
      onOverflow: { _ in })

    connection.bind(to: testRoot, generation: 1)

    XCTAssertTrue(
      connection.validateBinding(registry: host.sessionRoots), "binding invalid before replacement")

    TestSessionRoot.remove(from: host)
    TestSessionRoot.record(in: host, generation: 2)

    XCTAssertFalse(
      connection.validateBinding(registry: host.sessionRoots),
      "old generation still valid after replacement")
  }
}
