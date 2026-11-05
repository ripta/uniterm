import Foundation

/// What names a column across loads, restores, and sorts.
///
/// A column is its key-segment list plus its occurrence among columns with the same segments. So two
/// `amount` headers are two columns, and a restored sort lands on the right one. A column with no
/// segments is positional: a headerless CSV column, or one whose header cell is empty. Its
/// occurrence is its zero-based position.
public struct ColumnIdentity: Hashable, Codable, Sendable {
  public var segments: [String]
  public var occurrence: Int

  public init(segments: [String], occurrence: Int) {
    self.segments = segments
    self.occurrence = occurrence
  }

  public static func named(_ name: String, occurrence: Int = 0) -> ColumnIdentity {
    ColumnIdentity(segments: [name], occurrence: occurrence)
  }

  public static func positional(_ index: Int) -> ColumnIdentity {
    ColumnIdentity(segments: [], occurrence: index)
  }

  public var isPositional: Bool { segments.isEmpty }
}

/// One column of a table: its identity and the title the header shows.
public struct TableColumn: Sendable, Equatable {
  public let identity: ColumnIdentity
  public let title: String

  public init(identity: ColumnIdentity, title: String) {
    self.identity = identity
    self.title = title
  }

  /// The columns for a table of `count` columns. A header cell that is empty or only space leaves
  /// its column positional, and so does a column past the end of the header.
  static func columns(header: [String]?, count: Int) -> [TableColumn] {
    var seen: [String: Int] = [:]
    var columns: [TableColumn] = []
    columns.reserveCapacity(count)

    for index in 0..<count {
      let name = header.flatMap { index < $0.count ? $0[index] : nil } ?? ""

      if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        columns.append(
          TableColumn(identity: .positional(index), title: "Column \(index + 1)"))
        continue
      }

      let occurrence = seen[name, default: 0]
      seen[name] = occurrence + 1
      columns.append(TableColumn(identity: .named(name, occurrence: occurrence), title: name))
    }

    return columns
  }
}
