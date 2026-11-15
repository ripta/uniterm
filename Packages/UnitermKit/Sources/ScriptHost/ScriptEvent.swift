import Foundation
import ScriptWire

/// Why the listener turned a peer away.
public enum ScriptRefusal: Sendable, Equatable {
  /// The peer runs as another user.
  case otherUser(uid: uid_t)

  /// The peer's protocol version is not this app's. The user is told to relaunch uniterm.
  case versionMismatch(found: UInt16)

  /// The peer sent bytes the protocol does not allow, or none in time.
  case protocolViolation(String)

  /// A REPL presented a token the app did not issue, or one it had already accepted.
  case replTokenRefused

  /// The app already serves as many peers as it allows.
  case tooManyConnections

  /// The peer stopped reading replies, so the app ended the connection.
  case peerNotReading

  /// A program that already has a script or a REPL connected tried to begin another. A command
  /// opens its session before any script code runs, so a second one comes from script code.
  case secondSession

  /// What the user is told.
  public var text: String {
    switch self {
    case .otherUser(let uid):
      return "A program run by another user (\(uid)) tried to script uniterm."
    case .versionMismatch: return ScriptProtocol.mismatchText
    case .protocolViolation(let detail): return "A script connection broke the protocol: \(detail)"
    case .replTokenRefused:
      return "A REPL presented a token that uniterm did not issue, or had already accepted."
    case .tooManyConnections: return "Too many scripts are connected to uniterm."
    case .peerNotReading: return "A script stopped reading uniterm's replies and was disconnected."
    case .secondSession:
      return "A program that already has a script or a REPL connected tried to begin another."
    }
  }
}

/// What the listener hands to the main actor, in order. Every event is already decoded and
/// checked.
public enum ScriptEvent: Sendable {
  case begun(ScriptConnection, name: String)

  /// A helper declared the connection a controller run, in place of naming a script.
  case controllerBegun(ScriptConnection, ControllerBegin)

  /// A helper declared the connection a run of a declared script file.
  case fileBegun(ScriptConnection, FileBegin)

  /// A helper reported what the app's copy of its file declares, as JSON text. The app reads it
  /// strictly before it believes any of it.
  case fileDeclared(ScriptConnection, json: String)
  case request(ScriptConnection, id: UInt32, call: ScriptCall)

  /// A REPL's helper presented its token. It is the first message of the connection.
  case attached(ScriptConnection, token: Data)

  /// A REPL's helper reports a line the user entered.
  case replLine(ScriptConnection, String)

  /// A REPL's helper reports whether a form is evaluating.
  case replEvaluating(ScriptConnection, Bool)

  /// A helper answered a ping.
  case pong(ScriptConnection, UInt32)

  /// A REPL's helper is ending itself because it reached its memory cap.
  case replMemoryLimit(ScriptConnection)
  case closed(ScriptConnection)
  case refused(ScriptPeer?, ScriptRefusal)
}
