import Darwin
import Foundation
import PaneModel
import ScriptWire
import XCTest

@testable import ScriptHost

/// A stand-in for the window layer, with fixed answers keyed by the IDs a fixture script passes.
/// Window 7 is open, pane 404 is closed, and pane 403 is one that refuses. A nearest target names
/// pane 2.
///
/// It stands in for the layer only to prove how a script's call travels through the helper, the
/// wire, and the host. The window layer's own tests prove what the calls do to real windows.
@MainActor
final class FakeWindowAPI: ScriptWindowAPI {
  struct Sent: Equatable {
    var name: String
    var content: Data
    var size: Int
    var fileMode: mode_t
    var folderMode: mode_t
  }

  /// Every call that reached the app, oldest first, in the wire's own terms.
  private(set) var calls: [ScriptCall] = []
  private(set) var sent: [Sent] = []

  /// The panes a send asked about before it wrote anything.
  private(set) var prepared: [ScriptTarget] = []

  /// The caller the host named for each call, oldest first.
  private(set) var callers: [ScriptCaller] = []

  /// False for a test that sends many large files and only needs to count them.
  var keepsContent = true

  /// Panes that closed. Pane 6 closes as soon as it takes a file.
  private(set) var closedPanes: Set<UInt64> = []

  /// How many windows `listWindows` reports.
  var windowCount = 2

  func listWindows(caller: ScriptCaller) throws -> ScriptValue {
    calls.append(.listWindows)
    callers.append(caller)

    return .array(
      (0..<windowCount).map { index in
        .record([
          "window": .integer(ScriptProtocol.maxID - UInt64(index)),
          "title": .string("Synthetic \(index)"),
          "key": .bool(index == 0),
        ])
      })
  }

  func listPanes(window: UInt64, caller: ScriptCaller) throws -> ScriptValue {
    calls.append(.listPanes(window: window))
    callers.append(caller)

    guard window == 7 else { return .null }

    func tab(_ number: UInt64) -> ScriptValue {
      .record([
        "window": .integer(7), "pane": .integer(1), "tab": .integer(number),
        "title": .string("tab \(number)"), "selected": .bool(number == 1),
      ])
    }

    return .array([
      .record([
        "window": .integer(7), "pane": .integer(1), "applet": .string("terminal"),
        "title": .string("Synthetic"), "focused": .bool(true),
        "directory": .string("/synthetic/work"), "tabs": .array([tab(1), tab(2)]),
      ]),
      .record([
        "window": .integer(7), "pane": .integer(2), "applet": .string("browser"),
        "title": .string("Page"), "focused": .bool(false), "tabs": .array([tab(3)]),
      ]),
    ])
  }

  /// While true, `openPane` and `openTab` wait where the real layer checks a directory, until
  /// the test calls `releaseWait`.
  var holdsDirectoryCheck = false

  /// True while a call waits in its directory check.
  private(set) var isWaitingInDirectoryCheck = false

  /// How many panes and tabs a call went on to open.
  private(set) var opened = 0

  private var waiting: CheckedContinuation<Void, Never>?

  func releaseWait() {
    waiting?.resume()
    waiting = nil
  }

  /// Stands in for the real layer's directory check, the one wait between a call's start and its
  /// effect. The real layer asks `stillAllowed` right after it.
  private func directoryCheck(stillAllowed: @MainActor () throws -> Void) async throws {
    if holdsDirectoryCheck {
      isWaitingInDirectoryCheck = true
      await withCheckedContinuation { waiting = $0 }
      isWaitingInDirectoryCheck = false
    }

    try stillAllowed()
  }

  func openPane(
    kind: String, beside target: ScriptTarget, axis: ScriptAxis?, directory: String?,
    access: ScriptPaneAccess, caller: ScriptCaller, stillAllowed: @MainActor () throws -> Void
  ) async throws -> ScriptValue {
    calls.append(
      .openPane(kind: kind, beside: target, axis: axis, directory: directory, access: access))
    callers.append(caller)

    guard kind != "bogus" else { throw ScriptCallError.badArgument("the applet kind is not known") }

    try await directoryCheck(stillAllowed: stillAllowed)

    let beside = Self.reference(target)
    try check(beside)

    opened += 1

    return .record(["window": .integer(beside.window), "pane": .integer(99)])
  }

  func openTab(
    pane target: ScriptTarget, directory: String?, caller: ScriptCaller,
    stillAllowed: @MainActor () throws -> Void
  ) async throws -> ScriptValue {
    calls.append(.openTab(pane: target, directory: directory))
    callers.append(caller)

    let pane = Self.reference(target)

    guard pane.pane != 403 else {
      throw ScriptCallError.refused("the pane's applet has no tabs to open")
    }

    try await directoryCheck(stillAllowed: stillAllowed)
    try check(pane)

    opened += 1

    return .record([
      "window": .integer(pane.window), "pane": .integer(pane.pane), "tab": .integer(5),
    ])
  }

  func isOpen(_ pane: ScriptPaneReference) -> Bool {
    pane.window == 7 && pane.pane != 404 && !closedPanes.contains(pane.pane)
  }

  /// A nearest target stands for pane 2 of window 7.
  static func reference(_ target: ScriptTarget) -> ScriptPaneReference {
    switch target {
    case .pane(let reference): return reference
    case .nearest: return ScriptPaneReference(window: 7, pane: 2)
    }
  }

  func prepareSend(to target: ScriptTarget, caller: ScriptCaller) throws -> ScriptPaneReference {
    prepared.append(target)
    callers.append(caller)

    let pane = Self.reference(target)

    guard pane.pane != 403 else {
      throw ScriptCallError.refused(
        "a program owns this pane's input, so content cannot be sent to it")
    }

    try check(pane)

    return pane
  }

  func send(to pane: ScriptPaneReference, file: URL, caller: ScriptCaller) throws -> ScriptValue {
    var info = stat()
    var folder = stat()

    XCTAssertEqual(stat(file.path, &info), 0)
    XCTAssertEqual(stat(file.deletingLastPathComponent().path, &folder), 0)

    let content = try Data(contentsOf: file)

    sent.append(
      Sent(
        name: file.lastPathComponent, content: keepsContent ? content : Data(),
        size: content.count, fileMode: info.st_mode & 0o777,
        folderMode: folder.st_mode & 0o777))

    if pane.pane == 6 { closedPanes.insert(6) }

    return .null
  }

  /// Stands in for shared dispatch. A chart type or schema version 2 is unsupported, and the
  /// command `explode` is refused. Anything else echoes what arrived, with a negative and a
  /// fractional number so the reply proves both reach the script.
  func sendCommand(
    to target: ScriptTarget, appletType: String, schemaVersion: UInt32, command: String,
    arguments: String, caller: ScriptCaller, stillAllowed: @escaping @MainActor () throws -> Void
  ) async throws -> ScriptValue {
    calls.append(
      .sendCommand(
        pane: target, appletType: appletType, schemaVersion: schemaVersion, command: command,
        arguments: arguments))
    callers.append(caller)

    try check(Self.reference(target))

    guard appletType == "fixture-slides" else {
      throw ScriptCallError.unsupported("the pane runs a fixture-slides applet, not \(appletType)")
    }

    guard schemaVersion == 1 else {
      throw ScriptCallError.unsupported("the applet takes command schema version 1")
    }

    guard command != "explode" else { throw ScriptCallError.refused("the applet refused") }

    // A reply past the reply frame's bound, as an applet that answered with too much would make.
    if command == "huge-reply" {
      return .array(Array(repeating: .string(String(repeating: "r", count: 4000)), count: 20))
    }

    try stillAllowed()

    return .record([
      "command": .string(command), "arguments": .string(arguments), "offset": .number(-1.5),
    ])
  }

  private func check(_ pane: ScriptPaneReference) throws {
    guard pane.window == 7 else { throw ScriptCallError.notFound("the window is not open") }

    switch pane.pane {
    case 404: throw ScriptCallError.notFound("the pane is not open in that window")
    case 403: throw ScriptCallError.refused("the pane has no room to split")
    default: break
    }
  }
}
