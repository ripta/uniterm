import ControllerPackage
import ControllerTestSupport
import Darwin
import Foundation
import XCTest

@testable import ControllerTrust

/// Remembered approvals: how one request is compared with an approval, and how the policy file
/// is read, written, and kept when it cannot be used.
final class ControllerPolicyTests: XCTestCase {
  private var folder: URL!

  override func setUpWithError() throws {
    folder = try ControllerFixtures.temporaryFolder().appendingPathComponent("controllers")
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
  }

  private func launch(_ directory: String, keys: [String] = []) throws -> ControllerPermission {
    .hostLaunch(
      try HostLaunchScope(executable: "/usr/bin/true", directory: directory, environmentKeys: keys))
  }

  private static let version = String(repeating: "ab", count: 32)

  private static func policy(_ scopes: Set<ControllerPermission>) -> ControllerPolicy {
    ControllerPolicy(
      selector: .version(controllerID: "dev.uniterm.fixture.policy", version: Self.version),
      name: "Fixture", scopes: scopes, approved: "2026-11-11T10:00:00Z")
  }

  // MARK: Containment

  /// Catches a comparison that lets a broader or new power ride on an approval: another power, a
  /// directory outside the approved one, a sibling folder that shares its prefix, an extra
  /// environment key, or another executable. Narrower and equal requests are covered.
  func testOnlyAnUnchangedOrNarrowerRequestIsCovered() throws {
    let approved: Set<ControllerPermission> = [
      .paneControl, .clipboardRead, try launch("/work/project", keys: ["TOKEN", "HOME_URL"]),
    ]

    XCTAssertEqual(PermissionContainment.uncovered([.paneControl], by: approved), [])
    XCTAssertEqual(
      PermissionContainment.uncovered(
        [try launch("/work/project/sub", keys: ["TOKEN"])], by: approved), [])
    XCTAssertEqual(
      PermissionContainment.uncovered([try launch("/work/project")], by: approved), [])

    for wider in [
      ControllerPermission.clipboardWrite, .capability("fs-read"), try launch("/work"),
      try launch("/work/project-other"), try launch("/work/project", keys: ["TOKEN", "SECRET"]),
      .hostLaunch(
        try HostLaunchScope(executable: "/bin/sh", directory: "/work/project", environmentKeys: [])),
    ] {
      XCTAssertEqual(
        PermissionContainment.uncovered([.paneControl, wider], by: approved), [wider], "\(wider)")
    }
  }

  /// Catches a version rule that lets a higher version of a kind, or one this build does not know,
  /// ride on an approval of version 1, or that makes a format 1 approval useless for the same kind
  /// at version 1 in format 2.
  func testAFormatOneApprovalCoversVersionOneAndAHigherVersionNeedsReview() throws {
    let files = #"{"main.janet": "sha256:\#(String(repeating: "a", count: 64))"}"#
    let formatOne = try ControllerDescriptor.parse(
      Data(
        #"{"format": 1, "id": "dev.uniterm.fixture.v", "name": "X", "entry": {"kind": "janet", "path": "main.janet"}, "files": \#(files), "permissions": [{"kind": "pane-control"}]}"#
          .utf8))
    let formatTwo = try ControllerDescriptor.parse(
      Data(
        #"{"format": 2, "id": "dev.uniterm.fixture.v", "name": "X", "entry": {"kind": "janet", "path": "main.janet"}, "files": \#(files), "permissions": [{"kind": "pane-control", "version": 1}]}"#
          .utf8))

    XCTAssertEqual(
      PermissionContainment.uncovered(formatTwo.permissions, by: formatOne.permissions), [])

    let higher = ControllerPermission(.paneControl, version: 2)

    XCTAssertEqual(PermissionContainment.uncovered([higher], by: formatOne.permissions), [higher])
    XCTAssertFalse(
      higher.isCovered(by: higher), "a version this build does not know covers nothing")
  }

  // MARK: The file format

  /// Catches a codec that loses a selector, a scope, or a version on the way through the file, or
  /// that writes the same policies two ways.
  func testPoliciesRoundTripThroughTheFile() throws {
    let policies = [
      Self.policy([.paneControl, .clipboardWrite, try launch("/tmp", keys: ["B", "A"])]),
      ControllerPolicy(
        selector: .identity(
          controllerID: "dev.uniterm.fixture.signed",
          keyFingerprint: String(repeating: "c", count: 64)),
        name: "Signed \"one\"", scopes: [.capability("fs-read")], approved: "2026-11-11T11:00:00Z"),
    ]

    let bytes = ControllerPolicyFile.encode(policies)

    XCTAssertEqual(Set(try ControllerPolicyFile.decode(bytes)), Set(policies))
    XCTAssertEqual(ControllerPolicyFile.encode(policies.reversed()), bytes)
  }

  /// Catches a reader that reads a newer or unknown meaning as a narrower known one, or that takes
  /// a newer build's file for a broken one. A newer format, and a kind or version this build does
  /// not know, read as newer. A repeated key or an unknown field reads as broken.
  func testUnknownMeaningsReadAsNewerAndBrokenFilesAsUnreadable() throws {
    let good = String(
      decoding: ControllerPolicyFile.encode([Self.policy([.paneControl])]), as: UTF8.self)

    for (text, expected) in [
      (
        good.replacingOccurrences(
          of: "\"kind\": \"pane-control\"",
          with: "\"kind\": \"pane-everything\", \"reach\": \"far\""),
        "pane-everything version 1"
      ),
      (
        good.replacingOccurrences(of: "\"version\": 1", with: "\"version\": 2"),
        "pane-control version 2"
      ),
      (good.replacingOccurrences(of: "\"format\": 1", with: "\"format\": 2"), "format 2"),
    ] {
      XCTAssertThrowsError(try ControllerPolicyFile.decode(Data(text.utf8))) { error in
        XCTAssertEqual(error as? ControllerPolicyFileError, .newer(expected))
      }
    }

    for (text, expected) in [
      (
        good.replacingOccurrences(
          of: "\"name\": \"Fixture\"", with: "\"name\": \"Fixture\", \"name\": \"X\""), "twice"
      ),
      (
        good.replacingOccurrences(of: "\"approved\"", with: "\"trusted\": \"yes\", \"approved\""),
        "unknown field"
      ),
    ] {
      XCTAssertThrowsError(try ControllerPolicyFile.decode(Data(text.utf8))) { error in
        guard case .unreadable(let reason) = error as? ControllerPolicyFileError else {
          return XCTFail("\(error)")
        }

        XCTAssertTrue(reason.contains(expected), "\(reason) does not say \(expected)")
      }
    }
  }

  // MARK: The store

  /// Catches a policy file or folder another user can read, or a write that leaves a temp file.
  func testTheFileIsPrivateAndWrittenWhole() throws {
    let store = ControllerTrustStore(directory: folder)

    try store.update { _ in [Self.policy([.paneControl])] }

    var info = stat()

    XCTAssertEqual(stat(store.fileURL.path, &info), 0)
    XCTAssertEqual(info.st_mode & 0o777, 0o600)
    XCTAssertEqual(stat(folder.path, &info), 0)
    XCTAssertEqual(info.st_mode & 0o777, 0o700)

    let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)

    XCTAssertFalse(names.contains { $0.contains(".tmp-") }, "\(names)")
    XCTAssertEqual(store.read().policies, [Self.policy([.paneControl])])
  }

  /// Catches a corrupt file that grants something, that is overwritten and lost, or that blocks
  /// trust from then on. It grants nothing, is kept aside byte for byte, and a later write leaves
  /// the kept copy alone.
  func testACorruptFileGrantsNothingAndIsKeptForRecovery() throws {
    let store = ControllerTrustStore(directory: folder)

    try store.update { _ in [Self.policy([.paneControl])] }

    let corrupt = Data("{\"format\": 1, \"policies\": [".utf8)

    try corrupt.write(to: store.fileURL)

    let state = store.read()

    XCTAssertEqual(state.policies, [])
    XCTAssertTrue(state.writable)
    XCTAssertTrue(state.notice?.contains("policy.aside-1.json") == true, "\(state)")
    XCTAssertEqual(store.keptAsideFiles.count, 1)

    try store.update { _ in [Self.policy([.clipboardRead])] }

    XCTAssertEqual(try Data(contentsOf: store.keptAsideFiles[0]), corrupt)
    XCTAssertEqual(store.read().policies, [Self.policy([.clipboardRead])])
  }

  /// Catches an older build that trusts a newer file's policies, or rewrites the file and loses
  /// them. A newer format and a permission version this build lacks both grant nothing, write
  /// nothing, and leave the bytes where they are, so two builds that run together never move each
  /// other's file aside.
  func testANewerFileGrantsNothingAndIsLeftUntouched() throws {
    let store = ControllerTrustStore(directory: folder)
    let current = String(
      decoding: ControllerPolicyFile.encode([Self.policy([.paneControl])]), as: UTF8.self)

    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

    for newerText in [
      current.replacingOccurrences(of: "\"format\": 1", with: "\"format\": 7"),
      current.replacingOccurrences(of: "\"version\": 1", with: "\"version\": 4"),
    ] {
      let newer = Data(newerText.utf8)

      try newer.write(to: store.fileURL)

      let state = store.read()

      XCTAssertEqual(state.policies, [])
      XCTAssertFalse(state.writable)
      XCTAssertThrowsError(try store.update { _ in [Self.policy([.paneControl])] })
      XCTAssertEqual(try Data(contentsOf: store.fileURL), newer)
      XCTAssertEqual(store.keptAsideFiles, [])
    }
  }

  /// Catches a store that follows a link in place of its folder and makes the link's target
  /// private, or that waits forever on a policy file that is no regular file, such as a FIFO,
  /// while it holds the lock every other read needs. Both grant nothing, and neither changes or
  /// waits on anything.
  func testALinkedFolderOrASpecialFileGrantsNothingAndBlocksNothing() throws {
    let target = folder.deletingLastPathComponent().appendingPathComponent("elsewhere")

    try FileManager.default.createDirectory(
      at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
    try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: target)

    let linked = ControllerTrustStore(directory: folder).read()
    var info = stat()

    XCTAssertEqual(linked.policies, [])
    XCTAssertNotNil(linked.notice)
    XCTAssertEqual(stat(target.path, &info), 0)
    XCTAssertEqual(info.st_mode & 0o777, 0o755, "the store changed a folder it does not own")

    try FileManager.default.removeItem(at: folder)

    let store = ControllerTrustStore(directory: folder)

    try store.update { _ in [] }
    try FileManager.default.removeItem(at: store.fileURL)
    XCTAssertEqual(mkfifo(store.fileURL.path, 0o600), 0)

    let finished = DispatchSemaphore(value: 0)
    let result = LockedState()

    Thread.detachNewThread {
      result.set(store.read())
      finished.signal()
    }

    guard finished.wait(timeout: .now() + 5) == .success else {
      // Lets the blocked open go, so the thread does not outlive the test.
      let writer = open(store.fileURL.path, O_WRONLY | O_NONBLOCK)

      if writer >= 0 { close(writer) }

      return XCTFail("a read waited on a FIFO")
    }

    XCTAssertEqual(result.state?.policies, [])
    XCTAssertNotNil(result.state?.notice)
  }

  /// Catches two instances that each rewrite the file from what they read earlier, so one loses
  /// the other's change. Every change rereads the file under the lock.
  func testTwoStoresOnOneFolderKeepEachOthersChanges() throws {
    let first = ControllerTrustStore(directory: folder)
    let second = ControllerTrustStore(directory: folder)
    let other = ControllerPolicy(
      selector: .version(controllerID: "dev.uniterm.fixture.other", version: Self.version),
      name: "Other", scopes: [.paneControl], approved: "2026-11-11T10:00:00Z")

    try first.update { $0 + [Self.policy([.paneControl])] }
    try second.update { $0 + [other] }

    XCTAssertEqual(Set(first.read().policies), [Self.policy([.paneControl]), other])

    try second.update { $0.filter { $0.selector != other.selector } }

    XCTAssertEqual(first.read().policies, [Self.policy([.paneControl])])
  }
}

/// The state a read on another thread returned.
private final class LockedState: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: ControllerTrustState?

  func set(_ state: ControllerTrustState) {
    lock.lock()
    stored = state
    lock.unlock()
  }

  var state: ControllerTrustState? {
    lock.lock()
    defer { lock.unlock() }

    return stored
  }
}
