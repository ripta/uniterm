import Foundation
@_exported import HelperWire

/// What the protocol version and its sizes mean for both sides. A mismatch is refused before any
/// call runs.
///
/// The hello is one message with one field, in every version. A peer built against another
/// version can therefore always read the other's hello, and the refusal names the version.
public enum ScriptProtocol {
  public static let version: UInt16 = 8

  /// What the user is told when the two sides disagree. The app and its command are two binaries
  /// in one bundle, so replacing the bundle under a running app pairs an old app with a new one.
  public static let mismatchText =
    "The uniterm command and the app come from different versions. Relaunch uniterm."

  /// The largest body any message may declare. The reader checks it before it allocates.
  public static let maxControlBody = 64 * 1024

  /// The size of a controller's version digest, a SHA-256.
  public static let versionDigestBytes = 32

  /// The longest script name a peer may announce, in UTF-8 bytes.
  public static let maxNameBytes = 128

  /// The longest status text a script may post, in UTF-8 bytes. It matches the host function's own
  /// check in the Janet shim.
  public static let maxStatusBytes = 2048

  /// The longest failure message a reply may carry, in UTF-8 bytes.
  public static let maxFailureBytes = 512

  /// The largest ID a script may hold. A Janet number is a double, so every ID below this value is
  /// an exact integer in it.
  public static let maxID: UInt64 = (1 << 53) - 1

  /// The longest applet kind a script may name, in UTF-8 bytes.
  public static let maxKindBytes = 32

  /// The longest applet command name a script may send, in UTF-8 bytes.
  public static let maxCommandNameBytes = 64

  /// The most bytes of JSON one applet command's arguments may hold. It leaves room in the control
  /// frame for the rest of the call.
  public static let maxCommandArgumentBytes = 32 * 1024

  /// The most bytes of JSON one layout request may hold. It leaves room in the control frame for
  /// the rest of the call.
  public static let maxLayoutBytes = 32 * 1024

  /// The largest command schema version a script may name.
  public static let maxSchemaVersion: UInt32 = 1 << 31 - 1

  /// The longest directory a script may name, in UTF-8 bytes. It matches the system's path limit.
  public static let maxDirectoryBytes = 1024

  /// The longest file name a script may give to content it sends, in UTF-8 bytes. It matches the
  /// system's file name limit.
  public static let maxFileNameBytes = 255

  /// The most content one send may carry, in bytes. A send is the only message with a larger
  /// frame, so the reader allocates this much only for a message of its own type.
  public static let maxSendBytes = 1024 * 1024

  /// The largest payload a reply may carry. It leaves room in the frame for the reply's header.
  public static let maxReplyPayload = maxControlBody - 1024

  /// The environment variable the app passes a REPL's token in. The helper reads it first and then
  /// drops the whole environment.
  public static let replTokenVariable = "UNITERM_REPL_TOKEN"

  /// The size of a REPL's token, in bytes. Every byte is random.
  public static let tokenBytes = 32

  /// The longest line a REPL reports or recalls, in UTF-8 bytes. Janet's line editor holds 1023
  /// bytes of a line, so a line it returns always fits.
  public static let maxReplLineBytes = 1024

  /// The most lines one history message may carry. The app splits a longer history across
  /// messages, so no message passes the control frame's size.
  public static let historyLinesPerMessage = 32

  /// The most lines of a restored history the helper keeps to recall. It is the line editor's own
  /// limit. The app sends no more than this across all of a history's messages, and the helper
  /// refuses a history that holds more.
  public static let recallLines = 100

  /// The most memory one helper's Janet VM may hold, in bytes. The helper's allocator enforces it.
  /// It matches `UNITERM_JANET_DEFAULT_MEMORY_CAP` in the Janet shim, which a test proves.
  public static let helperMemoryCap = 1 << 30

  /// How far past the cap a REPL helper's footprint may go before the app kills it. The cap counts
  /// only what Janet's allocator hands out, and the footprint counts everything the process holds.
  public static let footprintKillMargin = helperMemoryCap / 4
}

/// Which way a new pane splits the pane beside it.
public enum ScriptAxis: UInt8, Sendable, Equatable, CaseIterable {
  /// The panes sit side by side.
  case row = 1

  /// The panes are stacked.
  case column = 2
}

/// How a script names a pane, or one tab of it. Every number is an exact integer that fits in a
/// Janet number. The app finds the window, pane, and tab only while they are open in this launch.
public struct ScriptPaneReference: Sendable, Equatable {
  public var window: UInt64
  public var pane: UInt64
  public var tab: UInt64?

  public init(window: UInt64, pane: UInt64, tab: UInt64? = nil) {
    self.window = window
    self.pane = pane
    self.tab = tab
  }
}

/// The pane a call acts on: one a script names, or the nearest pane of an applet type to the
/// caller's own pane. The app resolves a nearest target when it runs the call, among the panes the
/// caller may control, and never opens one when none matches.
public enum ScriptTarget: Sendable, Equatable {
  case pane(ScriptPaneReference)

  /// The kind is an applet type, such as `browser`.
  case nearest(kind: String)
}

/// The access a pane a script opens starts with. A script can enable control only on a pane it
/// creates in its own group, never on a pane that exists.
public enum ScriptPaneAccess: UInt8, Sendable, Equatable, CaseIterable {
  case disconnected = 0
  case remoteControlled = 1
}

extension ByteWriter {
  mutating func put(target: ScriptTarget) {
    switch target {
    case .pane(let reference):
      put(UInt8(0))
      put(reference: reference)

    case .nearest(let kind):
      put(UInt8(1))
      put(string: kind, limit: ScriptProtocol.maxKindBytes)
    }
  }

  mutating func put(id: UInt64) {
    put(UInt32(truncatingIfNeeded: id >> 32))
    put(UInt32(truncatingIfNeeded: id))
  }

  mutating func put(reference: ScriptPaneReference) {
    put(id: reference.window)
    put(id: reference.pane)

    if let tab = reference.tab {
      put(UInt8(1))
      put(id: tab)
    } else {
      put(UInt8(0))
    }
  }

  /// A string that may be absent. A flag says which.
  mutating func put(optional text: String?, limit: Int) {
    guard let text else {
      put(UInt8(0))
      return
    }

    put(UInt8(1))
    put(string: text, limit: limit)
  }
}

extension ByteReader {
  /// An ID. One above `ScriptProtocol.maxID` cannot be a Janet integer, so the app never sees it
  /// from a helper that checks its arguments.
  mutating func id() throws -> UInt64 {
    let high = UInt64(try u32())
    let low = UInt64(try u32())
    let value = high << 32 | low

    guard value <= ScriptProtocol.maxID else {
      throw WireError.badValue("an ID is too large for a script number")
    }

    return value
  }

  mutating func reference() throws -> ScriptPaneReference {
    let window = try id()
    let pane = try id()

    switch try u8() {
    case 0: return ScriptPaneReference(window: window, pane: pane)
    case 1: return ScriptPaneReference(window: window, pane: pane, tab: try id())
    default: throw WireError.badValue("a reference has an unknown tab flag")
    }
  }

  mutating func target() throws -> ScriptTarget {
    switch try u8() {
    case 0: return .pane(try reference())
    case 1: return .nearest(kind: try string(limit: ScriptProtocol.maxKindBytes))
    default: throw WireError.badValue("a target has an unknown form")
    }
  }

  /// JSON text with a 32-bit length before it. The length is checked against `limit` before any
  /// byte is read. `what` names the text in the error, such as "the layout is".
  mutating func json(limit: Int, what: String) throws -> String {
    let count = Int(try u32())

    guard count <= limit else { throw WireError.tooLong(declared: count, limit: limit) }

    guard remaining >= count else { throw WireError.truncated }

    var bytes = Data()

    for _ in 0..<count { bytes.append(try u8()) }

    guard let text = String(data: bytes, encoding: .utf8) else {
      throw WireError.badValue("\(what) not UTF-8")
    }

    return text
  }

  mutating func optionalString(limit: Int) throws -> String? {
    switch try u8() {
    case 0: return nil
    case 1: return try string(limit: limit)
    default: throw WireError.badValue("an optional string has an unknown flag")
    }
  }
}

/// How serious a script's status message is.
public enum ScriptStatusLevel: UInt8, Sendable, Equatable, CaseIterable {
  case info = 0
  case warning = 1
  case error = 2
}

/// A host function call. Each case is one function, named on the wire by a 16-bit code that never
/// changes meaning. A new function takes a new code and keeps the others.
public enum ScriptCall: Equatable, Sendable {
  case postStatus(level: ScriptStatusLevel, text: String)
  case listWindows
  case listPanes(window: UInt64)
  case openPane(
    kind: String, beside: ScriptTarget, axis: ScriptAxis?, directory: String?,
    access: ScriptPaneAccess)
  case openTab(pane: ScriptTarget, directory: String?)
  case send(pane: ScriptTarget, name: String, content: Data)

  /// One applet command for a pane. It names the applet type and the command schema version the
  /// script was written for, and the app refuses either when the pane does not support it. The
  /// arguments are a JSON object as text, which the app checks against the applet's schema.
  case sendCommand(
    pane: ScriptTarget, appletType: String, schemaVersion: UInt32, command: String,
    arguments: String)

  /// A layout for the caller's subtree, anchored at a pane it may control. The layout is a JSON
  /// object as text, which the app parses and checks.
  case requestLayout(pane: ScriptTarget, layout: String)

  var code: UInt16 {
    switch self {
    case .postStatus: return 1
    case .listWindows: return 2
    case .listPanes: return 3
    case .openPane: return 4
    case .openTab: return 5
    case .send: return 6
    case .sendCommand: return 7
    case .requestLayout: return 8
    }
  }

  /// The code of the one call that carries content, and so has a frame of its own type.
  static let sendCode: UInt16 = 6

  func encode(into body: inout ByteWriter) {
    body.put(code)

    switch self {
    case .postStatus(let level, let text):
      body.put(level.rawValue)
      body.put(string: text, limit: ScriptProtocol.maxStatusBytes)

    case .listWindows:
      break

    case .listPanes(let window):
      body.put(id: window)

    case .openPane(let kind, let beside, let axis, let directory, let access):
      body.put(string: kind, limit: ScriptProtocol.maxKindBytes)
      body.put(target: beside)
      body.put(axis?.rawValue ?? 0)
      body.put(optional: directory, limit: ScriptProtocol.maxDirectoryBytes)
      body.put(access.rawValue)

    case .openTab(let pane, let directory):
      body.put(target: pane)
      body.put(optional: directory, limit: ScriptProtocol.maxDirectoryBytes)

    case .send(let pane, let name, let content):
      body.put(target: pane)
      body.put(string: name, limit: ScriptProtocol.maxFileNameBytes)
      body.put(raw: content)

    case .sendCommand(let pane, let type, let version, let command, let arguments):
      body.put(target: pane)
      body.put(string: type, limit: ScriptProtocol.maxKindBytes)
      body.put(version)
      body.put(string: command, limit: ScriptProtocol.maxCommandNameBytes)
      let bytes = Data(arguments.utf8.prefix(ScriptProtocol.maxCommandArgumentBytes))

      body.put(UInt32(bytes.count))
      body.put(raw: bytes)

    case .requestLayout(let pane, let layout):
      body.put(target: pane)

      let bytes = Data(layout.utf8.prefix(ScriptProtocol.maxLayoutBytes))

      body.put(UInt32(bytes.count))
      body.put(raw: bytes)
    }
  }

  /// Public because the helper reads back the call its shim wrote, before it sends the call.
  public static func decode(from reader: inout ByteReader) throws -> ScriptCall {
    switch try reader.u16() {
    case 1:
      guard let level = ScriptStatusLevel(rawValue: try reader.u8()) else {
        throw WireError.badValue("an unknown status level")
      }

      return .postStatus(
        level: level, text: try reader.string(limit: ScriptProtocol.maxStatusBytes))

    case 2:
      return .listWindows

    case 3:
      return .listPanes(window: try reader.id())

    case 4:
      let kind = try reader.string(limit: ScriptProtocol.maxKindBytes)
      let beside = try reader.target()
      let axisByte = try reader.u8()

      guard axisByte == 0 || ScriptAxis(rawValue: axisByte) != nil else {
        throw WireError.badValue("an unknown split axis")
      }

      let directory = try reader.optionalString(limit: ScriptProtocol.maxDirectoryBytes)

      guard let access = ScriptPaneAccess(rawValue: try reader.u8()) else {
        throw WireError.badValue("an unknown pane access")
      }

      return .openPane(
        kind: kind, beside: beside, axis: ScriptAxis(rawValue: axisByte), directory: directory,
        access: access)

    case 5:
      return .openTab(
        pane: try reader.target(),
        directory: try reader.optionalString(limit: ScriptProtocol.maxDirectoryBytes))

    case 6:
      let pane = try reader.target()
      let name = try reader.string(limit: ScriptProtocol.maxFileNameBytes)
      let content = reader.rest()

      guard content.count <= ScriptProtocol.maxSendBytes else {
        throw WireError.tooLong(declared: content.count, limit: ScriptProtocol.maxSendBytes)
      }

      return .send(pane: pane, name: name, content: content)

    case 7:
      let pane = try reader.target()
      let type = try reader.string(limit: ScriptProtocol.maxKindBytes)
      let version = try reader.u32()

      guard version <= ScriptProtocol.maxSchemaVersion else {
        throw WireError.badValue("a schema version is too large")
      }

      let command = try reader.string(limit: ScriptProtocol.maxCommandNameBytes)
      let arguments = try reader.json(
        limit: ScriptProtocol.maxCommandArgumentBytes, what: "the arguments are")

      return .sendCommand(
        pane: pane, appletType: type, schemaVersion: version, command: command,
        arguments: arguments)

    case 8:
      let pane = try reader.target()
      let layout = try reader.json(limit: ScriptProtocol.maxLayoutBytes, what: "the layout is")

      return .requestLayout(pane: pane, layout: layout)

    default:
      throw WireError.badValue("an unknown host function")
    }
  }
}

/// Why a call did not succeed. The kind lets a script tell its own mistake from a refusal.
public enum ScriptFailureKind: UInt8, Sendable, Equatable {
  /// The call's arguments are not acceptable.
  case badArgument = 1

  /// The app declined the call, such as for a missing window.
  case refused = 2

  /// The app failed while it ran the call.
  case failed = 3

  /// The window, pane, or tab the call names is not open in this launch. It may have closed, or
  /// the reference may come from an earlier launch. The text never names another pane.
  case notFound = 4

  /// The pane runs another applet type than the call names, or does not support the command
  /// schema version it names. Nothing ran.
  case unsupported = 5

  /// The applet command ran, and its reply could not be sent to the script. The command's effect
  /// stands, so the script must not take this for a refusal.
  case replyLost = 6

  /// The app is still working on another call of the same kind from this caller, such as a layout
  /// it is preparing. Nothing ran, and the call may be sent again once the other one is answered.
  case busy = 7
}

/// The app's answer to one call.
public enum ScriptResult: Equatable, Sendable {
  /// The call ran. The payload is the function's result, which is empty for a function that
  /// returns nothing.
  case ok(Data)

  case failure(ScriptFailureKind, String)
}

/// A run of a controller package, which the bundle's own command asks the app to admit. It names
/// the package by path and nothing else. The app reads, verifies, and copies the package itself, so
/// a digest or a name the peer could claim never reaches it.
public struct ControllerBegin: Equatable, Sendable {
  public enum Entry: UInt8, Sendable, Equatable, CaseIterable {
    /// The command runs the package's Janet entry in its own VM, once the app admits it.
    case janet = 1

    /// The command execs the package's native entry from the app's snapshot.
    case native = 2
  }

  /// The most capabilities one run may ask for, and the longest name of one.
  public static let maxCapabilities = 32
  public static let maxCapabilityBytes = 32

  public let entry: Entry

  /// The package folder's absolute path, with every link resolved by the command.
  public let package: String

  /// The Janet capabilities the user granted the run with `--allow`. Each must be one the
  /// descriptor declares.
  public let capabilities: [String]

  public init(entry: Entry, package: String, capabilities: [String] = []) {
    self.entry = entry
    self.package = package
    self.capabilities = capabilities
  }
}

/// A message from a script helper. The app validates each one and trusts none of them.
public enum ScriptHelperMessage: Equatable, Sendable {
  case hello(version: UInt16)

  /// Names the script, or the REPL, that the connection serves. The name labels the script's
  /// messages in the status bar.
  case begin(name: String)

  /// A host function call. The reply carries the same request ID.
  case request(id: UInt32, call: ScriptCall)

  /// A REPL helper presents its single-use token. It is the first message after the hello, in
  /// place of `begin`, and names the REPL pane the connection serves.
  case attach(token: Data)

  /// A line the user entered in the REPL, reported before it is evaluated. The app keeps its own
  /// copy of the history from these.
  case replLine(String)

  /// Whether the REPL is evaluating a form now. The app asks it before it closes the pane.
  case replEvaluating(Bool)

  /// The answer to the app's ping. The helper's watchdog thread sends it, never the VM thread, so
  /// a busy VM still answers.
  case pong(UInt32)

  /// The helper's allocator is about to end the process for passing its memory cap. The helper
  /// writes this frame itself, in one write, before it exits.
  case memoryLimit

  /// Declares the connection a controller run, in place of `begin`. The app answers with
  /// `controllerAdmitted` or `controllerRefused`, and no call is answered before that.
  case controllerBegin(ControllerBegin)

  /// The frame type of the one call that carries content.
  static let sendType: UInt8 = 4

  var wireType: UInt8 {
    switch self {
    case .hello: return 1
    case .begin: return 2
    case .request(_, let call):
      if case .send = call { return Self.sendType }

      return 3
    case .attach: return 5
    case .replLine: return 6
    case .replEvaluating: return 7
    case .pong: return 8
    case .memoryLimit: return 9
    case .controllerBegin: return 10
    }
  }

  public func frame() -> Data {
    var body = ByteWriter()

    switch self {
    case .hello(let version): body.put(version)

    case .begin(let name): body.put(string: name, limit: ScriptProtocol.maxNameBytes)

    case .pong(let nonce): body.put(nonce)

    case .memoryLimit: break

    case .controllerBegin(let begin):
      body.put(begin.entry.rawValue)
      body.put(string: begin.package, limit: ScriptProtocol.maxDirectoryBytes)
      body.put(UInt8(min(begin.capabilities.count, ControllerBegin.maxCapabilities)))

      for name in begin.capabilities.prefix(ControllerBegin.maxCapabilities) {
        body.put(string: name, limit: ControllerBegin.maxCapabilityBytes)
      }

    case .attach(let token): body.put(raw: token)

    case .replLine(let text): body.put(string: text, limit: ScriptProtocol.maxReplLineBytes)

    case .replEvaluating(let running): body.put(running ? UInt8(1) : UInt8(0))

    case .request(let id, let call):
      body.put(id)
      call.encode(into: &body)
    }

    return FrameHeader.frame(type: wireType, body: body.bytes)
  }

  /// The most body bytes a message of `type` may declare.
  public static func bodyLimit(type: UInt8) -> Int {
    type == sendType
      ? ScriptProtocol.maxSendBytes + ScriptProtocol.maxControlBody : ScriptProtocol.maxControlBody
  }

  public static func decode(type: UInt8, body: Data) throws -> ScriptHelperMessage {
    var reader = ByteReader(body)
    let message: ScriptHelperMessage

    switch type {
    case 1: message = .hello(version: try reader.u16())

    case 2: message = .begin(name: try reader.string(limit: ScriptProtocol.maxNameBytes))

    case 3, sendType:
      let id = try reader.u32()
      let call = try ScriptCall.decode(from: &reader)

      var isSend = false

      if case .send = call { isSend = true }

      guard isSend == (type == sendType) else {
        throw WireError.badValue("a call is in a frame of the wrong type")
      }

      message = .request(id: id, call: call)

    case 5:
      let token = reader.rest()

      guard token.count == ScriptProtocol.tokenBytes else {
        throw WireError.badValue("a token is not \(ScriptProtocol.tokenBytes) bytes")
      }

      message = .attach(token: token)

    case 6: message = .replLine(try reader.string(limit: ScriptProtocol.maxReplLineBytes))

    case 7:
      switch try reader.u8() {
      case 0: message = .replEvaluating(false)
      case 1: message = .replEvaluating(true)
      default: throw WireError.badValue("an evaluating flag is not 0 or 1")
      }

    case 8: message = .pong(try reader.u32())

    case 9: message = .memoryLimit

    case 10:
      guard let entry = ControllerBegin.Entry(rawValue: try reader.u8()) else {
        throw WireError.badValue("an unknown controller entry kind")
      }

      let package = try reader.string(limit: ScriptProtocol.maxDirectoryBytes)
      let count = Int(try reader.u8())

      guard count <= ControllerBegin.maxCapabilities else {
        throw WireError.tooLong(declared: count, limit: ControllerBegin.maxCapabilities)
      }

      var capabilities: [String] = []

      for _ in 0..<count {
        capabilities.append(try reader.string(limit: ControllerBegin.maxCapabilityBytes))
      }

      message = .controllerBegin(
        ControllerBegin(entry: entry, package: package, capabilities: capabilities))

    default: throw WireError.unknownType(type)
    }

    try reader.finished()

    return message
  }

  /// What the app checks of the helper's hello.
  public static func validateHello(_ message: ScriptHelperMessage) throws {
    guard case .hello(let version) = message else {
      throw WireError.badValue("the helper did not start with a hello")
    }

    guard version == ScriptProtocol.version else {
      throw WireError.versionMismatch(found: version, expected: ScriptProtocol.version)
    }
  }
}

/// A message from the app. The helper validates each one.
public enum ScriptAppMessage: Equatable, Sendable {
  case hello(version: UInt16)

  case reply(id: UInt32, result: ScriptResult)

  /// The app turned a REPL's token away. The text says why, and the helper shows it and ends.
  case attachRefused(String)

  /// Lines of history for the REPL's line editor to recall, oldest first. The helper never
  /// evaluates them. The last message of a history has `final` set, and an empty history is one
  /// empty message with it set, so the helper always knows the app accepted its token.
  case history(lines: [String], final: Bool)

  /// A liveness probe. The helper's watchdog thread answers with a pong that carries the same
  /// nonce, whatever the VM thread is doing.
  case ping(UInt32)

  /// The user asked to stop what the helper is running. The watchdog thread carries it out by
  /// signalling the VM thread, which interrupts the form the way Ctrl-C does. It changes nothing
  /// when no form is running.
  case stop

  /// The app verified the controller and admitted the run. `snapshot` is the folder of the run's
  /// private copy, and `version` the SHA-256 of its descriptor. The command loads only what that
  /// folder holds, and only when its descriptor has that digest.
  case controllerAdmitted(snapshot: String, version: Data)

  /// The app refused the run. The text says why, and the command shows it and runs nothing.
  case controllerRefused(String)

  var wireType: UInt8 {
    switch self {
    case .hello: return 1
    case .reply: return 2
    case .attachRefused: return 3
    case .history: return 4
    case .ping: return 5
    case .stop: return 6
    case .controllerAdmitted: return 7
    case .controllerRefused: return 8
    }
  }

  public func frame() -> Data {
    var body = ByteWriter()

    switch self {
    case .hello(let version): body.put(version)

    case .reply(let id, let result):
      body.put(id)

      switch result {
      case .ok(let payload):
        body.put(UInt8(0))
        body.put(raw: payload)

      case .failure(let kind, let text):
        body.put(kind.rawValue)
        body.put(string: text, limit: ScriptProtocol.maxFailureBytes)
      }

    case .attachRefused(let text):
      body.put(string: text, limit: ScriptProtocol.maxFailureBytes)

    case .ping(let nonce): body.put(nonce)

    case .stop: break

    case .controllerAdmitted(let snapshot, let version):
      body.put(string: snapshot, limit: ScriptProtocol.maxDirectoryBytes)
      body.put(raw: version.prefix(ScriptProtocol.versionDigestBytes))

    case .controllerRefused(let text):
      body.put(string: text, limit: ScriptProtocol.maxFailureBytes)

    case .history(let lines, let final):
      body.put(final ? UInt8(1) : UInt8(0))
      body.put(UInt16(min(lines.count, ScriptProtocol.historyLinesPerMessage)))

      for line in lines.prefix(ScriptProtocol.historyLinesPerMessage) {
        body.put(string: line, limit: ScriptProtocol.maxReplLineBytes)
      }
    }

    return FrameHeader.frame(type: wireType, body: body.bytes)
  }

  public static func bodyLimit(type: UInt8) -> Int {
    ScriptProtocol.maxControlBody
  }

  public static func decode(type: UInt8, body: Data) throws -> ScriptAppMessage {
    var reader = ByteReader(body)

    switch type {
    case 1:
      let version = try reader.u16()
      try reader.finished()

      return .hello(version: version)

    case 2:
      let id = try reader.u32()
      let status = try reader.u8()

      if status == 0 {
        return .reply(id: id, result: .ok(reader.rest()))
      }

      guard let kind = ScriptFailureKind(rawValue: status) else {
        throw WireError.badValue("an unknown failure kind")
      }

      let text = try reader.string(limit: ScriptProtocol.maxFailureBytes)
      try reader.finished()

      return .reply(id: id, result: .failure(kind, text))

    case 3:
      let text = try reader.string(limit: ScriptProtocol.maxFailureBytes)
      try reader.finished()

      return .attachRefused(text)

    case 4:
      let final: Bool

      switch try reader.u8() {
      case 0: final = false
      case 1: final = true
      default: throw WireError.badValue("a history flag is not 0 or 1")
      }

      let count = Int(try reader.u16())

      guard count <= ScriptProtocol.historyLinesPerMessage else {
        throw WireError.tooLong(declared: count, limit: ScriptProtocol.historyLinesPerMessage)
      }

      var lines: [String] = []

      for _ in 0..<count {
        lines.append(try reader.string(limit: ScriptProtocol.maxReplLineBytes))
      }

      try reader.finished()

      return .history(lines: lines, final: final)

    case 5:
      let nonce = try reader.u32()
      try reader.finished()

      return .ping(nonce)

    case 6:
      try reader.finished()

      return .stop

    case 7:
      let snapshot = try reader.string(limit: ScriptProtocol.maxDirectoryBytes)
      let version = reader.rest()

      guard version.count == ScriptProtocol.versionDigestBytes else {
        throw WireError.badValue(
          "a controller version is not \(ScriptProtocol.versionDigestBytes) bytes")
      }

      return .controllerAdmitted(snapshot: snapshot, version: version)

    case 8:
      let text = try reader.string(limit: ScriptProtocol.maxFailureBytes)
      try reader.finished()

      return .controllerRefused(text)

    default:
      throw WireError.unknownType(type)
    }
  }

  /// What the helper checks of the app's hello.
  public static func validateHello(_ message: ScriptAppMessage) throws {
    guard case .hello(let version) = message else {
      throw WireError.badValue("the app did not start with a hello")
    }

    guard version == ScriptProtocol.version else {
      throw WireError.versionMismatch(found: version, expected: ScriptProtocol.version)
    }
  }
}
