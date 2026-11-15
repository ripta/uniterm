import AppletKit
import Foundation
import PaneModel
import ScriptHost
import ScriptWire

/// A layout a controller asks for, read from JSON. A script sends it through
/// `uniterm/request-layout`, and an exec driver in a `layout` message.
///
/// A node is one of three objects. `{"split": "row", "children": [...]}` is a split, with two or
/// more children. `{"pane": 3}` is a pane already open in the caller's window, and may name that
/// window as `"window"`. `{"open": "fixture-notes"}` is a new pane, with `"control"` of
/// `"disconnected"` or `"remote-controlled"`, an absolute `"directory"`, and an `"exec"`
/// declaration of `"argv"`, `"directory"`, and `"environment-keys"` as options. Any node may take
/// a positive `"weight"`, which is relative to its siblings and defaults to 1. A key outside
/// these is refused, so a misspelled option never goes unnoticed.
///
/// Reading checks the shape, the bounds, the kinds, and that each kind supports the control and
/// driver asked of it. It checks no authority and no directory on disk. The window does both.
struct LayoutRequest: Equatable {
  /// A pane the layout opens, as the request asks for it.
  struct NewPane: Equatable {
    let kind: String
    let choice: AppletChoice
    let access: PaneAccessMode
    let directory: String?
    let exec: ExecDeclaration?

    var combination: ControlCombination {
      ControlCombination(access: access, driver: exec == nil ? .none : .exec)
    }
  }

  let plan: PaneLayoutPlan
  let panes: [NewPane]

  /// The most leaves one layout may hold. It bounds the applets one request can build.
  static let maxLeaves = 16

  /// The most splits one path through a layout may cross.
  static let maxDepth = 6

  static func parse(
    _ value: JSONValue, window: UInt64, declarations: [AppletTypeDeclaration]
  ) throws(ScriptCallError) -> LayoutRequest {
    var reader = Reader(window: window, declarations: declarations)
    let plan = try reader.node(value, depth: 0, at: "the layout")

    return LayoutRequest(plan: plan, panes: reader.panes)
  }

  /// Reads JSON text, as a script sends it.
  static func parse(
    _ text: String, window: UInt64, declarations: [AppletTypeDeclaration]
  ) throws(ScriptCallError) -> LayoutRequest {
    let value: JSONValue

    do {
      value = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    } catch {
      throw .badArgument("the layout is not a JSON object")
    }

    return try parse(value, window: window, declarations: declarations)
  }

  /// The applet choice for a kind a script names: a built-in one, or a type the window declares
  /// beyond them. Nil for a kind the window does not know.
  static func choice(forKind kind: String, in declarations: [AppletTypeDeclaration])
    -> AppletChoice?
  {
    if let builtIn = WindowScripting.kinds.first(where: { $0.name == kind }) {
      return builtIn.choice
    }

    guard declarations.contains(where: { $0.typeID == kind }) else { return nil }

    return .hosted(typeID: kind)
  }

  private struct Reader {
    let window: UInt64
    let declarations: [AppletTypeDeclaration]
    var panes: [NewPane] = []
    var leaves = 0

    init(window: UInt64, declarations: [AppletTypeDeclaration]) {
      self.window = window
      self.declarations = declarations
    }

    mutating func node(_ value: JSONValue, depth: Int, at path: String) throws(ScriptCallError)
      -> PaneLayoutPlan
    {
      guard case .object(let fields) = value else {
        throw .badArgument("\(path) is not an object")
      }

      let forms = ["split", "pane", "open"].filter { fields[$0] != nil }

      guard forms.count == 1, let form = forms.first else {
        throw .badArgument("\(path) must hold exactly one of split, pane, or open")
      }

      switch form {
      case "split":
        try only(fields, ["split", "children", "weight"], at: path)
        return try split(fields, depth: depth, at: path)

      case "pane":
        try only(fields, ["pane", "window", "weight"], at: path)
        try countLeaf(at: path)
        return .existing(try existing(fields, at: path))

      default:
        try only(fields, ["open", "control", "directory", "exec", "weight"], at: path)
        try countLeaf(at: path)
        panes.append(try newPane(fields, at: path))
        return .new(slot: panes.count - 1)
      }
    }

    private mutating func split(_ fields: [String: JSONValue], depth: Int, at path: String)
      throws(ScriptCallError) -> PaneLayoutPlan
    {
      guard depth < LayoutRequest.maxDepth else {
        throw .badArgument("the layout nests more than \(LayoutRequest.maxDepth) splits deep")
      }

      let axis: Axis

      switch fields["split"] {
      case .string("row")?: axis = .row
      case .string("column")?: axis = .column
      default: throw .badArgument("\(path)'s split must be row or column")
      }

      guard case .array(let items)? = fields["children"], items.count >= 2 else {
        throw .badArgument("\(path) must have two or more children")
      }

      var children: [PaneLayoutPlan.Child] = []

      for (index, item) in items.enumerated() {
        let at = "child \(index + 1) of \(path)"
        let plan = try node(item, depth: depth + 1, at: at)

        children.append(PaneLayoutPlan.Child(plan: plan, weight: try weight(of: item, at: at)))
      }

      return .split(axis: axis, children: children)
    }

    private func weight(of value: JSONValue, at path: String) throws(ScriptCallError) -> Double {
      guard case .object(let fields) = value, let raw = fields["weight"] else { return 1 }

      guard case .number(let weight) = raw, weight.isFinite, weight > 0, weight <= 1_000 else {
        throw .badArgument("\(path)'s weight must be a number above 0 and at most 1000")
      }

      return weight
    }

    private mutating func countLeaf(at path: String) throws(ScriptCallError) {
      leaves += 1

      guard leaves <= LayoutRequest.maxLeaves else {
        throw .badArgument("the layout holds more than \(LayoutRequest.maxLeaves) panes")
      }
    }

    /// A pane the caller names. Another window's pane is out of reach, and answers as one that is
    /// not open.
    private func existing(_ fields: [String: JSONValue], at path: String) throws(ScriptCallError)
      -> NodeID
    {
      if let named = fields["window"] {
        guard let id = Self.id(named) else {
          throw .badArgument("\(path)'s window must be a whole number")
        }

        guard id == window else { throw .notFound("the window is not open") }
      }

      guard let pane = fields["pane"].flatMap(Self.id), pane > 0 else {
        throw .badArgument("\(path)'s pane must be a whole number above 0")
      }

      return NodeID(rawValue: pane)
    }

    private func newPane(_ fields: [String: JSONValue], at path: String) throws(ScriptCallError)
      -> NewPane
    {
      guard case .string(let kind)? = fields["open"], !kind.isEmpty,
        kind.utf8.count <= ScriptProtocol.maxKindBytes
      else { throw .badArgument("\(path)'s open must name an applet kind") }

      guard let choice = LayoutRequest.choice(forKind: kind, in: declarations) else {
        throw .badArgument("\(path) opens \(kind), which this window does not know")
      }

      let access: PaneAccessMode

      switch fields["control"] {
      case nil, .string("disconnected")?: access = .disconnected
      case .string("remote-controlled")?: access = .remoteControlled
      default: throw .badArgument("\(path)'s control must be disconnected or remote-controlled")
      }

      var directory: String?

      if let value = fields["directory"] {
        guard case .string(let text) = value, text.hasPrefix("/"), !text.utf8.contains(0),
          text.utf8.count <= ScriptProtocol.maxDirectoryBytes
        else { throw .badArgument("\(path)'s directory must be an absolute path") }

        guard choice != .browser else { throw .badArgument("a browser has no directory") }

        directory = text
      }

      let exec = try fields["exec"].map { value throws(ScriptCallError) in
        try declaration(value, at: path)
      }

      let pane = NewPane(
        kind: kind, choice: choice, access: access, directory: directory, exec: exec)

      guard
        AppletTypeDeclaration.supportedControl(forType: kind, in: declarations).contains(
          pane.combination)
      else {
        throw .refused("a \(kind) pane does not support \(pane.combination) control")
      }

      return pane
    }

    private func declaration(_ value: JSONValue, at path: String) throws(ScriptCallError)
      -> ExecDeclaration
    {
      guard case .object(let fields) = value else {
        throw .badArgument("\(path)'s exec is not an object")
      }

      try only(fields, ["argv", "directory", "environment-keys"], at: "\(path)'s exec")

      guard case .array(let argv)? = fields["argv"] else {
        throw .badArgument("\(path)'s exec has no argv")
      }

      let arguments = argv.compactMap { if case .string(let text) = $0 { text } else { nil } }
      var directory: String?
      var keys: [String] = []

      guard arguments.count == argv.count else {
        throw .badArgument("\(path)'s argv must hold strings")
      }

      if let value = fields["directory"] {
        guard case .string(let text) = value else {
          throw .badArgument("\(path)'s exec directory must be a string")
        }

        directory = text
      }

      if let value = fields["environment-keys"] {
        guard case .array(let names) = value else {
          throw .badArgument("\(path)'s environment-keys must be a list")
        }

        keys = names.compactMap { if case .string(let text) = $0 { text } else { nil } }

        guard keys.count == names.count else {
          throw .badArgument("\(path)'s environment-keys must hold strings")
        }
      }

      do {
        return try ExecDeclaration(
          arguments: arguments, directory: directory, environmentKeys: keys)
      } catch {
        throw .badArgument("\(path)'s exec cannot run: \(error)")
      }
    }

    private func only(_ fields: [String: JSONValue], _ allowed: Set<String>, at path: String)
      throws(ScriptCallError)
    {
      if let unknown = fields.keys.sorted().first(where: { !allowed.contains($0) }) {
        let names = allowed.sorted().joined(separator: ", ")

        throw .badArgument(
          "\(path) has the unknown key \(unknown.prefix(32)). Its keys are \(names)")
      }
    }

    /// A whole number a script can hold exactly.
    private static func id(_ value: JSONValue) -> UInt64? {
      guard case .number(let number) = value, number.isFinite, number >= 0,
        number == number.rounded(), number <= Double(ScriptProtocol.maxID)
      else { return nil }

      return UInt64(number)
    }
  }
}
