import AppletKit
import Foundation

/// An applet type the palette can filter by, as its declaration names it.
struct PaletteAppletType: Hashable, Sendable {
  let typeID: String
  let name: String
  let symbolName: String

  init(_ declaration: AppletTypeDeclaration) {
    typeID = declaration.typeID
    name = declaration.displayName
    symbolName = declaration.symbolName
  }
}

/// What the palette's chip narrows the list to. The field holds at most one, and choosing another
/// replaces it.
enum PaletteFilter: Hashable, Sendable {
  /// The tabs of one applet type. Its commands stay out, so the list holds only its tabs.
  case applet(PaletteAppletType)

  case tabs
  case commands

  /// The word typed before the colon. Each category offers its own values.
  enum Category: String, CaseIterable, Sendable {
    case applet
    case kind

    var keyword: String { rawValue + ":" }
  }

  var category: Category {
    switch self {
    case .applet: .applet
    case .tabs, .commands: .kind
    }
  }

  /// What the chip and the suggestion row say.
  var name: String {
    switch self {
    case .applet(let type): type.name
    case .tabs: "Tabs"
    case .commands: "Commands"
    }
  }

  var symbolName: String {
    switch self {
    case .applet(let type): type.symbolName
    case .tabs: "rectangle.on.rectangle"
    case .commands: PaletteEntry.commandSymbol
    }
  }

  /// What the empty field says while the chip is in it.
  var placeholder: String {
    switch self {
    case .applet(let type): "Search \(type.name) tabs"
    case .tabs: "Search tabs"
    case .commands: "Search commands"
    }
  }

  func admits(_ entry: PaletteEntry) -> Bool {
    switch self {
    case .applet(let type): entry.kind == .tab && entry.appletTypeID == type.typeID
    case .tabs: entry.kind == .tab
    case .commands: entry.kind == .command
    }
  }

  /// What the list says when the filter leaves nothing.
  func emptyNotice(queryIsEmpty: Bool) -> String {
    switch self {
    case .applet(let type):
      queryIsEmpty ? "No \(type.name) tabs in this window" : "No \(type.name) tabs match"
    case .tabs: "No tabs match"
    case .commands: "No commands match"
    }
  }
}

/// Builds the palette's rows from the candidates, the text, and the chip.
///
/// Text that starts with a keyword, such as `applet:br`, lists that category's values instead of
/// results. Two or more letters that start a keyword add a hint row above the results. The chip
/// keeps only the candidates it admits, and the text then searches among those.
enum PaletteListing {
  /// The fewest letters that offer a keyword. One letter would offer one on most queries.
  static let hintMinimumLength = 2

  static let hintSymbol = "line.3.horizontal.decrease.circle"

  static func entries(
    _ candidates: [PaletteCandidate], query: String, filter: PaletteFilter?,
    appletTypes: [PaletteAppletType]
  ) -> [PaletteEntry] {
    let typed = query.trimmingCharacters(in: .whitespaces).lowercased()

    for category in PaletteFilter.Category.allCases where typed.hasPrefix(category.keyword) {
      let rest = String(typed.dropFirst(category.keyword.count))
        .trimmingCharacters(in: .whitespaces)

      return suggestions(category, matching: rest, appletTypes: appletTypes)
    }

    var rows: [PaletteEntry] = []

    if typed.count >= hintMinimumLength, !typed.contains(":") {
      for category in PaletteFilter.Category.allCases where category.keyword.hasPrefix(typed) {
        rows.append(
          PaletteEntry(
            id: .filterKeyword(category), kind: .filterKeyword, title: category.keyword,
            symbolName: hintSymbol, detail: nil, isEnabled: true))
      }
    }

    let admitted = filter.map { filter in candidates.filter { filter.admits($0.entry) } }
    let ranked = PaletteRanking.rank(admitted ?? candidates, query: query)

    if let filter, ranked.isEmpty {
      rows.append(
        notice(filter.emptyNotice(queryIsEmpty: PaletteRanking.isEmpty(query))))
    }

    return rows + ranked
  }

  /// The values of a category whose name has a word that starts with `rest`, such as `data` or
  /// `viewer` for Data Viewer. An applet's type ID matches too.
  private static func suggestions(
    _ category: PaletteFilter.Category, matching rest: String,
    appletTypes: [PaletteAppletType]
  ) -> [PaletteEntry] {
    let values: [PaletteFilter]

    switch category {
    case .applet: values = appletTypes.map { .applet($0) }
    case .kind: values = [.tabs, .commands]
    }

    let matching = values.filter { value in
      if case .applet(let type) = value, type.typeID.hasPrefix(rest) { return true }

      return startsAWord(rest, in: value.name)
    }

    guard !matching.isEmpty else {
      let shown = PaletteText.neutralized(rest)

      return [notice("No \(category.rawValue) named \u{201C}\(shown)\u{201D}")]
    }

    return matching.map { value in
      PaletteEntry(
        id: .filter(value), kind: .filter, title: value.name, symbolName: value.symbolName,
        detail: nil, isEnabled: true)
    }
  }

  private static func startsAWord(_ prefix: String, in name: String) -> Bool {
    let lower = name.lowercased()

    return lower.hasPrefix(prefix)
      || lower.split(separator: " ").contains { $0.hasPrefix(prefix) }
  }

  private static func notice(_ text: String) -> PaletteEntry {
    PaletteEntry(id: .notice, kind: .notice, title: text, detail: nil, isEnabled: true)
  }
}
