import AppletKit
import Foundation

/// A place a remote scroll names. It never carries text. A heading is its position in the contents
/// list, so a controller learns no heading text from naming one.
public enum RemoteAnchor: Equatable, Sendable {
  /// A PDF page counted from zero, with an optional point on the page in page points.
  case page(Int, x: Double?, y: Double?)

  /// An entry of the contents list, counted from zero.
  case heading(Int)

  /// A Markdown source line counted from zero, and how far down its block the top of the view is.
  case line(Int, fraction: Double)

  /// A character index, in UTF-16 units, in an RTF or Word document.
  case character(Int)

  public static let maxPage = 1_000_000
  public static let maxLine = 1 << 28
  public static let maxPoint = 1_000_000.0

  private static let kinds = ["page", "heading", "line", "character"]

  /// The fields each kind takes besides `kind`.
  private static let fieldsByKind: [String: Set<String>] = [
    "page": ["page", "x", "y"], "heading": ["heading"], "line": ["line", "fraction"],
    "character": ["character"],
  ]

  public static let schema = AppletValueSchema.object(
    AppletObjectSchema([
      "kind": .init(.choice(kinds)),
      "page": .init(.integer(minimum: 0, maximum: maxPage), required: false),
      "x": .init(.number(minimum: -maxPoint, maximum: maxPoint), required: false),
      "y": .init(.number(minimum: -maxPoint, maximum: maxPoint), required: false),
      "heading": .init(.integer(minimum: 0, maximum: Contents.maxEntries), required: false),
      "line": .init(.integer(minimum: 0, maximum: maxLine), required: false),
      "fraction": .init(.number(minimum: 0, maximum: 1), required: false),
      "character": .init(
        .integer(minimum: 0, maximum: TextViewerLimits.standard.maxDecodedLength), required: false),
    ]))

  /// Reads an anchor the schema already accepted. A field that does not belong to the kind, or a
  /// required one that is missing, is a bad argument.
  public init(json: JSONValue) throws(AppletCommandError) {
    guard case .object(let fields) = json, case .string(let kind)? = fields["kind"],
      let allowed = Self.fieldsByKind[kind]
    else { throw AppletCommandError(.badArgument, "the anchor needs a kind") }

    for name in fields.keys.sorted() where name != "kind" && !allowed.contains(name) {
      throw AppletCommandError(.badArgument, "a \(kind) anchor has no field \"\(name)\"")
    }

    func whole(_ name: String) -> Int? {
      guard case .number(let number)? = fields[name] else { return nil }

      return Int(number)
    }

    func real(_ name: String) -> Double? {
      guard case .number(let number)? = fields[name] else { return nil }

      return number
    }

    func required(_ name: String) throws(AppletCommandError) -> Int {
      guard let value = whole(name) else {
        throw AppletCommandError(.badArgument, "a \(kind) anchor needs the field \"\(name)\"")
      }

      return value
    }

    switch kind {
    case "page":
      self = .page(try required("page"), x: real("x"), y: real("y"))

    case "heading":
      self = .heading(try required("heading"))

    case "line":
      self = .line(try required("line"), fraction: real("fraction") ?? 0)

    default:
      self = .character(try required("character"))
    }
  }

  /// An anchor in a reply, in the same shape a scroll takes. Nil when the anchor holds nothing a
  /// controller could use.
  public static func json(of anchor: TextViewerAnchor) -> JSONValue? {
    if let page = anchor.page {
      var fields: [String: JSONValue] = ["kind": .string("page"), "page": .number(Double(page))]

      if let x = anchor.x, x.isFinite { fields["x"] = .number(x) }

      if let y = anchor.y, y.isFinite { fields["y"] = .number(y) }

      return .object(fields)
    }

    if let index = anchor.characterIndex {
      return .object(["kind": .string("character"), "character": .number(Double(index))])
    }

    if let line = anchor.sourceLine {
      return .object([
        "kind": .string("line"), "line": .number(Double(line)),
        "fraction": .number(min(1, max(0, anchor.fraction ?? 0))),
      ])
    }

    return nil
  }
}
