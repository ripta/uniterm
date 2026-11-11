import AppletKit
import CoreGraphics
import Foundation
import PaneModel

/// Why a layout file could not be read as a whole. A single applet description that is unknown,
/// newer, or corrupt is not one of these. It becomes a placeholder pane.
public enum LayoutReadError: Error, Equatable, CustomStringConvertible {
  /// The bytes are not a JSON document with the expected top level.
  case unreadable(String)

  /// The file was written by a newer build.
  case newerSchema(found: Int, supported: Int)

  /// The file is older than any version this build can upgrade from.
  case olderSchema(found: Int)

  public var description: String {
    switch self {
    case .unreadable(let reason):
      return "the file is not a readable layout: \(reason)"

    case .newerSchema(let found, let supported):
      return "the file uses schema version \(found), and this build reads up to \(supported)"

    case .olderSchema(let found):
      return "the file uses schema version \(found), which this build cannot upgrade"
    }
  }
}

/// Upgrades a layout document one schema version at a time.
public struct LayoutMigrations: Sendable {
  public typealias Step = @Sendable (Data) throws -> Data

  /// Maps a version to the step that turns a document of that version into the next one.
  private let steps: [Int: Step]

  public init(steps: [Int: Step] = [:]) {
    self.steps = steps
  }

  /// The steps this build ships.
  ///
  /// Version 2 adds the group node and a pane's saved control. A version 1 file holds neither, so
  /// its windows read as they are, and every pane comes back disconnected with no group.
  public static let standard = LayoutMigrations(steps: [1: LayoutCodec.upgradeFromVersion1])

  /// Upgrades `document` from `version` to `target`, applying each step in turn. A missing step
  /// means the version is not upgradable. The result carries the target version.
  func upgrade(_ document: Data, from version: Int, to target: Int) throws -> Data {
    var data = document
    var current = version

    while current < target {
      guard let step = steps[current] else { throw LayoutReadError.olderSchema(found: version) }

      data = try step(data)
      current += 1
    }

    return data
  }
}

/// Reads and writes the layout file's JSON.
///
/// The top level is `{"version": 2, "windows": [...]}`.
///
/// A window holds its frame, its screen, its focused pane, the high-water mark of its node IDs,
/// and a tree. A tree node is a pane with an applet description, a split with an axis and
/// weighted children, or a group around one node. A pane may name the control it had, and a
/// group names its source and its members. Neither grants anything on restore.
///
/// Each description keeps its own type and version.
public enum LayoutCodec {
  /// The largest node ID or high-water mark a file may hold. A larger value is never written by
  /// this build. A hand-edited one could make the allocator run out of IDs.
  public static let maximumNodeID: UInt64 = 1 << 48

  /// The schema version this build writes.
  public static let currentVersion = 2

  /// A version 1 document carries over unchanged under the version 2 number. Only the windows
  /// list is kept, byte for byte, so no applet description is rewritten.
  @Sendable
  static func upgradeFromVersion1(_ document: Data) throws -> Data {
    guard let windows = try RawJSON(document).member("windows") else {
      throw LayoutReadError.unreadable("the windows list is missing")
    }

    return Data(#"{"version":2,"windows":"#.utf8) + windows.bytes + Data("}".utf8)
  }

  // MARK: Writing

  /// Writes the layout. A weight that is not a positive finite number is replaced by an equal
  /// share, and a frame that is not usable by a default one, so one bad number can never make the
  /// next launch reject the whole file.
  public static func encode(_ layout: SavedLayout) throws -> Data {
    let document = JSONOut.object([
      ("version", .integer(Int64(currentVersion))),
      ("windows", .array(try layout.windows.map(encode))),
    ])

    return document.serialized()
  }

  private static func encode(_ window: SavedWindow) throws -> JSONOut {
    let usable =
      window.frame.minX.isFinite && window.frame.minY.isFinite && window.frame.width.isFinite
      && window.frame.height.isFinite && window.frame.width > 0 && window.frame.height > 0
    let frame = usable ? window.frame : CGRect(x: 0, y: 0, width: 960, height: 640)

    var members: [(String, JSONOut)] = [("frame", encode(frame))]

    if let screen = window.screen, screen.width.isFinite, screen.height.isFinite,
      screen.minX.isFinite, screen.minY.isFinite, screen.width > 0, screen.height > 0
    {
      members.append(("screen", encode(screen)))
    }

    if let focused = window.focusedPane {
      members.append(("focusedPane", .unsigned(focused.rawValue)))
    }

    members.append(("highWaterMark", .unsigned(window.highWaterMark)))
    members.append(("tree", try encode(window.tree)))
    return .object(members)
  }

  private static func encode(_ rect: CGRect) -> JSONOut {
    .object([
      ("x", .number(rect.minX)), ("y", .number(rect.minY)),
      ("width", .number(rect.width)), ("height", .number(rect.height)),
    ])
  }

  private static func encode(_ node: SavedNode) throws -> JSONOut {
    switch node {
    case .pane(let id, let applet, let control):
      var members: [(String, JSONOut)] = [
        ("kind", .string("pane")), ("id", .unsigned(id.rawValue)),
      ]

      if control != .disconnected {
        members.append(
          (
            "control",
            .object([
              ("access", .string(control.access.rawValue)),
              ("driver", .string(control.driver.rawValue)),
            ])
          ))
      }

      members.append(("applet", try encode(applet)))
      return .object(members)

    case .group(let id, let source, let groupMembers, let inner):
      var members: [(String, JSONOut)] = [
        ("kind", .string("group")), ("id", .unsigned(id.rawValue)),
      ]

      if let source { members.append(("source", .unsigned(source.rawValue))) }

      members.append(("members", .array(groupMembers.sorted().map { .unsigned($0.rawValue) })))
      members.append(("node", try encode(inner)))
      return .object(members)

    case .split(let id, let axis, let children):
      return .object([
        ("kind", .string("split")), ("id", .unsigned(id.rawValue)),
        ("axis", .string(axis == .row ? "row" : "column")),
        (
          "children",
          .array(
            try children.map {
              let valid = $0.weight.isFinite && $0.weight > 0
              let weight = valid ? $0.weight : 1 / Double(children.count)
              return .object([("weight", .number(weight)), ("node", try encode($0.node))])
            })
        ),
      ])
    }
  }

  private static func encode(_ description: AppletDescription) throws -> JSONOut {
    if let verbatim = description.verbatim {
      return .raw(verbatim)
    }

    return .object([
      ("type", .string(description.type)), ("version", .integer(Int64(description.version))),
      ("payload", .raw(try JSONEncoder().encode(description.payload))),
    ])
  }

  // MARK: Reading

  /// Reads a layout file. Throws when the file as a whole cannot be used. An applet description
  /// that cannot be read comes back as a description with its bytes in `verbatim`, and the applet
  /// type ID `unreadable` when it has no type.
  public static func decode(
    _ data: Data, migrations: LayoutMigrations = .standard
  ) throws -> SavedLayout {
    do {
      _ = try JSONSerialization.jsonObject(with: data, options: [])
    } catch {
      throw LayoutReadError.unreadable("\(error.localizedDescription)")
    }

    let root = RawJSON(data)

    guard let versionValue = try? root.member("version"), let version = versionValue.integer else {
      throw LayoutReadError.unreadable("the version is missing or not an integer")
    }

    guard version <= currentVersion else {
      throw LayoutReadError.newerSchema(found: version, supported: currentVersion)
    }

    guard version >= 1 else { throw LayoutReadError.olderSchema(found: version) }

    let upgraded = try migrations.upgrade(data, from: version, to: currentVersion)
    return try decodeCurrent(RawJSON(upgraded))
  }

  private static func decodeCurrent(_ root: RawJSON) throws -> SavedLayout {
    do {
      guard let windowList = try root.member("windows") else {
        throw LayoutReadError.unreadable("the windows list is missing")
      }

      return SavedLayout(windows: try windowList.elements().map(decodeWindow))
    } catch let error as LayoutReadError {
      throw error
    } catch {
      throw LayoutReadError.unreadable("\(error)")
    }
  }

  private static func decodeWindow(_ raw: RawJSON) throws -> SavedWindow {
    let members = Members(try raw.members())

    guard let frameValue = members["frame"], let frame = try decodeRect(frameValue) else {
      throw LayoutReadError.unreadable("a window has no frame")
    }

    var screen: CGRect?
    if let screenValue = members["screen"] {
      screen = try decodeRect(screenValue)
    }

    guard let treeValue = members["tree"] else {
      throw LayoutReadError.unreadable("a window has no tree")
    }

    var seen = Set<NodeID>()
    let tree = try decodeNode(treeValue, seen: &seen)

    var focused: NodeID?
    if let value = members["focusedPane"]?.unsignedInteger {
      let candidate = NodeID(rawValue: value)
      focused = tree.paneIDs.contains(candidate) ? candidate : nil
    }

    let stored = members["highWaterMark"]?.unsignedInteger ?? 0
    let mark = min(stored, maximumNodeID)

    return SavedWindow(
      frame: frame, screen: screen, tree: tree, focusedPane: focused, highWaterMark: mark)
  }

  private static func decodeRect(_ raw: RawJSON) throws -> CGRect? {
    let members = Members(try raw.members())

    guard let x = members["x"]?.number, let y = members["y"]?.number,
      let width = members["width"]?.number, let height = members["height"]?.number,
      width > 0, height > 0
    else { return nil }

    return CGRect(x: x, y: y, width: width, height: height)
  }

  private static func decodeNode(_ raw: RawJSON, seen: inout Set<NodeID>) throws -> SavedNode {
    let members = Members(try raw.members())

    guard let kind = members["kind"]?.text else {
      throw LayoutReadError.unreadable("a node has no kind")
    }

    guard let value = members["id"]?.unsignedInteger, value > 0, value <= maximumNodeID
    else {
      throw LayoutReadError.unreadable("a node has no valid ID")
    }

    let id = NodeID(rawValue: value)

    guard seen.insert(id).inserted else {
      throw LayoutReadError.unreadable("node \(id) appears more than once")
    }

    switch kind {
    case "pane":
      guard let applet = members["applet"] else {
        throw LayoutReadError.unreadable("pane \(id) has no applet")
      }

      return .pane(
        id: id, applet: decodeDescription(applet), control: decodeControl(members["control"]))

    case "group":
      guard let nodeValue = members["node"] else {
        throw LayoutReadError.unreadable("group \(id) has no node")
      }

      let inner = try decodeNode(nodeValue, seen: &seen)
      let panes = Set(inner.paneIDs)

      var source: NodeID?
      if let value = members["source"] {
        guard let raw = value.unsignedInteger, raw > 0, raw <= maximumNodeID else {
          throw LayoutReadError.unreadable("group \(id) has no valid source")
        }

        source = NodeID(rawValue: raw)
      }

      guard let list = try members["members"]?.elements() else {
        throw LayoutReadError.unreadable("group \(id) has no members list")
      }

      var listed: [NodeID] = []

      for item in list {
        guard let raw = item.unsignedInteger, raw > 0, raw <= maximumNodeID else {
          throw LayoutReadError.unreadable("group \(id) has a member without a valid ID")
        }

        // A member outside the group's own node names nothing the group holds. It is dropped,
        // so a damaged list can only shrink a group.
        let member = NodeID(rawValue: raw)

        if panes.contains(member), !listed.contains(member) { listed.append(member) }
      }

      return .group(id: id, source: source, members: listed, node: inner)

    case "split":
      guard let axisName = members["axis"]?.text, axisName == "row" || axisName == "column"
      else { throw LayoutReadError.unreadable("split \(id) has no valid axis") }

      guard let list = try members["children"]?.elements(), list.count >= 2 else {
        throw LayoutReadError.unreadable("split \(id) has fewer than two children")
      }

      var children: [SavedChild] = []

      for item in list {
        let childMembers = Members(try item.members())

        guard let weight = childMembers["weight"]?.number, weight > 0,
          let nodeValue = childMembers["node"]
        else { throw LayoutReadError.unreadable("split \(id) has a child without a valid weight") }

        children.append(SavedChild(node: try decodeNode(nodeValue, seen: &seen), weight: weight))
      }

      return .split(id: id, axis: axisName == "row" ? .row : .column, children: children)

    default:
      throw LayoutReadError.unreadable("node \(id) has the unknown kind \(kind)")
    }
  }

  /// A pane's saved control. A missing, damaged, or unknown value reads as disconnected, since it
  /// is only intent and never grants anything.
  private static func decodeControl(_ raw: RawJSON?) -> SavedPaneControl {
    guard let raw, let members = try? Members(raw.members()) else { return .disconnected }

    let access = members["access"]?.text.flatMap(PaneAccessMode.init(rawValue:)) ?? .disconnected
    let driver =
      members["driver"]?.text.flatMap(PaneDriverKind.init(rawValue:)) ?? PaneDriverKind.none

    return SavedPaneControl(access: access, driver: driver)
  }

  /// The members of one object, scanned once. The last of a repeated key wins, as in JSON.
  private struct Members {
    private let values: [String: RawJSON]

    init(_ members: [(key: String, value: RawJSON)]) {
      values = Dictionary(members.map { ($0.key, $0.value) }, uniquingKeysWith: { $1 })
    }

    subscript(key: String) -> RawJSON? { values[key] }
  }

  /// Reads a description, and keeps its bytes whether or not it parses. The bytes are what a save
  /// writes back for an applet that could not be restored.
  static func decodeDescription(_ raw: RawJSON) -> AppletDescription {
    guard let members = try? raw.members(),
      let type = members.last(where: { $0.key == "type" })?.value.text,
      let version = members.last(where: { $0.key == "version" })?.value.integer,
      let payloadBytes = members.last(where: { $0.key == "payload" })?.value.bytes,
      let payload = try? JSONDecoder().decode(JSONValue.self, from: payloadBytes)
    else {
      return AppletDescription(
        type: "unreadable", version: 0, payload: .null, verbatim: raw.bytes)
    }

    return AppletDescription(type: type, version: version, payload: payload, verbatim: raw.bytes)
  }
}
