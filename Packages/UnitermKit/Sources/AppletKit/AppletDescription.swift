import Foundation

/// The restorable form of an applet.
///
/// A description is inert state. Restoring an applet from it never runs a program the user did not
/// ask to run at that moment. Each applet type versions its own payload.
public struct AppletDescription: Sendable, Equatable, Codable {
  public let type: String
  public let version: Int
  public let payload: JSONValue

  /// The exact bytes the layout file held for this description, when it came from a file. A saved
  /// layout writes them back unchanged for an applet that could not be restored, so a newer build
  /// still finds what it wrote. The payload of such a description is not meaningful.
  public let verbatim: Data?

  /// What undo restores beyond the payload, such as a terminal's closed tabs. It lives in memory
  /// with the window's undo state. A layout file never writes it and never reads it, and it is
  /// dropped at quit. Two descriptions that differ only here hold the same saved state.
  public let undoState: AppletUndoState?

  public init(
    type: String, version: Int, payload: JSONValue, verbatim: Data? = nil,
    undoState: AppletUndoState? = nil
  ) {
    self.type = type
    self.version = version
    self.payload = payload
    self.verbatim = verbatim
    self.undoState = undoState
  }

  /// The description as a layout file holds it, without the undo-only part.
  public var withoutUndoState: AppletDescription {
    AppletDescription(type: type, version: version, payload: payload, verbatim: verbatim)
  }

  private enum CodingKeys: String, CodingKey {
    case type
    case version
    case payload
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    type = try container.decode(String.self, forKey: .type)
    version = try container.decode(Int.self, forKey: .version)
    payload = try container.decode(JSONValue.self, forKey: .payload)
    verbatim = nil
    undoState = nil
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(type, forKey: .type)
    try container.encode(version, forKey: .version)
    try container.encode(payload, forKey: .payload)
  }
}

/// The undo-only part of a description, held as the applet's own value.
///
/// It never leaves the process, so nothing encodes it. An applet stores a value of its own type and
/// reads it back with `value(as:)`. A pane's close and its reopen then cost no conversion, however
/// large the part is.
///
/// Two parts are equal when they hold equal values of the same type.
public struct AppletUndoState: Sendable, Equatable {
  private let stored: any Sendable
  private let matches: @Sendable (any Sendable) -> Bool

  public init<Value: Sendable & Equatable>(_ value: Value) {
    stored = value
    matches = { ($0 as? Value) == value }
  }

  /// The value, or nil when the part holds another type, as from an applet of another kind.
  public func value<Value>(as type: Value.Type) -> Value? {
    stored as? Value
  }

  public static func == (lhs: AppletUndoState, rhs: AppletUndoState) -> Bool {
    lhs.matches(rhs.stored)
  }
}

/// Why an applet could not be restored from a description. A caller keeps the raw description and
/// shows a placeholder instead.
public enum AppletRestoreError: Error, Equatable {
  case wrongType(expected: String, found: String)
  case newerVersion(found: Int, supported: Int)
  case corrupt(String)
  case unsupported(String)
}
