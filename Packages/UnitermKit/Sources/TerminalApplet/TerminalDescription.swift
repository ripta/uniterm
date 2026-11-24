import AppletKit
import Foundation

/// The restorable state of a terminal applet.
///
/// It is inert. Restoring a terminal starts a fresh shell in each tab's directory. It never runs a
/// program. A program-mode terminal keeps its command here and shows it with a Run action.
public struct TerminalDescription: Codable, Equatable, Sendable {
  public enum Mode: String, Codable, Sendable {
    case shell
    case program
  }

  public struct Tab: Codable, Equatable, Sendable {
    /// The directory the shell reported last, or the directory the tab started in.
    public var workingDirectory: String?

    /// The directory the tab was launched in. A restore falls back to it when the reported
    /// directory is gone or was never local. A description written before this field existed
    /// reads as nil.
    public var startDirectory: String?

    public init(workingDirectory: String?, startDirectory: String? = nil) {
      self.workingDirectory = workingDirectory
      self.startDirectory = startDirectory
    }
  }

  public var mode: Mode
  public var command: String?
  public var tabs: [Tab]
  public var selectedTab: Int

  public init(mode: Mode, command: String? = nil, tabs: [Tab], selectedTab: Int = 0) {
    self.mode = mode
    self.command = command
    self.tabs = tabs
    self.selectedTab = selectedTab
  }

  public static let typeID = "terminal"

  /// The version of the payload this build reads and writes.
  public static let currentVersion = 1

  /// The description, with the closed tabs in its undo-only part when there are any. The payload
  /// is the same either way.
  public func appletDescription(closedTabs: [ClosedTab] = []) throws -> AppletDescription {
    AppletDescription(
      type: Self.typeID, version: Self.currentVersion, payload: try JSONValue(encoding: self),
      undoState: closedTabs.isEmpty
        ? nil : AppletUndoState(try JSONValue(encoding: UndoState(closedTabs: closedTabs))))
  }

  /// A tab the user closed, as undo needs it. The stamp orders it against every other close in the
  /// window. The index is where the tab sat after the close dialog returned.
  public struct ClosedTab: Codable, Equatable, Sendable {
    public var stamp: UInt64
    public var index: Int
    public var title: String
    public var tab: Tab

    public init(stamp: UInt64, index: Int, title: String, tab: Tab) {
      self.stamp = stamp
      self.index = index
      self.title = title
      self.tab = tab
    }
  }

  struct UndoState: Codable, Equatable, Sendable {
    var closedTabs: [ClosedTab]
  }

  /// The closed tabs a description carries, newest first. A description with no undo-only part, or
  /// one this build cannot read, carries none. That part is never saved, so nothing older exists.
  public static func closedTabs(in description: AppletDescription) -> [ClosedTab] {
    guard description.type == typeID,
      let state = try? description.undoState?.value(as: JSONValue.self)?.decoded(as: UndoState.self)
    else { return [] }

    return state.closedTabs
  }

  /// Reads a description. A description of another type, a newer version, or a shape that does not
  /// decode is refused, and the caller keeps the original.
  public static func decode(_ description: AppletDescription) throws -> TerminalDescription {
    guard description.type == typeID else {
      throw AppletRestoreError.wrongType(expected: typeID, found: description.type)
    }

    guard description.version <= currentVersion else {
      throw AppletRestoreError.newerVersion(
        found: description.version, supported: currentVersion)
    }

    let decoded: TerminalDescription
    do {
      decoded = try description.payload.decoded(as: TerminalDescription.self)
    } catch {
      throw AppletRestoreError.corrupt("terminal description: \(error)")
    }

    guard !decoded.tabs.isEmpty else {
      throw AppletRestoreError.corrupt("terminal description has no tabs")
    }

    guard decoded.tabs.indices.contains(decoded.selectedTab) else {
      throw AppletRestoreError.corrupt("terminal description selects a missing tab")
    }

    return decoded
  }
}
