import AppletKit
import Foundation

/// The tabs of a Questions pane and the rules that decide which form may open, which tab it uses,
/// and which tab gives way. It knows no views, so the rules test without a window.
///
/// A requester has at most one tab. An open form occupies it, and a resolved form leaves it for the
/// requester's next form. The cap counts both, but only open forms refuse a new requester. A
/// resolved tab never counts against a newcomer, since it gives way.
struct QuestionsBook: Equatable {
  /// The most tabs a pane holds, and so the most open forms.
  static let defaultCap = 8

  enum Phase: Equatable {
    case open

    /// The order in which forms resolved, so the oldest resolved tab is the first to give way.
    case resolved(order: Int)
  }

  struct Entry: Equatable {
    let id: AppletTabID
    let requesterKey: String
    var phase: Phase

    var isOpen: Bool { phase == .open }
  }

  /// Why a form is refused. Both are the wire's `busy` failure.
  enum Refusal: Equatable {
    /// The requester has an open form already.
    case requesterBusy

    /// Every tab the pane may hold holds an open form.
    case paneFull
  }

  /// Where a requester's arriving form goes.
  enum Admission: Equatable {
    /// The requester's own tab, which holds a resolved form.
    case reuse(AppletTabID)

    /// A new tab. A tab that gives way closes first, when the pane is at its cap.
    case new(evicting: AppletTabID?)

    case refused(Refusal)
  }

  let cap: Int
  private(set) var entries: [Entry] = []
  private(set) var selected: AppletTabID?
  private var resolutions = 0

  init(cap: Int = QuestionsBook.defaultCap) {
    self.cap = max(1, cap)
  }

  var isEmpty: Bool { entries.isEmpty }

  var openCount: Int { entries.filter(\.isOpen).count }

  func entry(_ id: AppletTabID) -> Entry? {
    entries.first { $0.id == id }
  }

  func entry(forRequester key: String) -> Entry? {
    entries.first { $0.requesterKey == key }
  }

  var selectedIndex: Int? {
    selected.flatMap { id in entries.firstIndex { $0.id == id } }
  }

  /// Decides where a requester's form goes, and changes nothing.
  func admission(forRequester key: String) -> Admission {
    if let own = entry(forRequester: key) {
      return own.isOpen ? .refused(.requesterBusy) : .reuse(own.id)
    }

    guard openCount < cap else { return .refused(.paneFull) }

    guard entries.count >= cap else { return .new(evicting: nil) }

    return .new(evicting: evictionCandidate())
  }

  /// The resolved tab that gives way for a new requester: the oldest one that is not selected.
  /// The selected tab gives way only when no other resolved tab is left.
  private func evictionCandidate() -> AppletTabID? {
    let resolved =
      entries.compactMap { entry -> (AppletTabID, Int)? in
        guard case .resolved(let order) = entry.phase else { return nil }

        return (entry.id, order)
      }
      .sorted { $0.1 < $1.1 }

    return resolved.first { $0.0 != selected }?.0 ?? resolved.first?.0
  }

  /// Opens a requester's form as admission decided. A reused tab becomes open again. A new tab
  /// joins the end of the bar. The tab is selected either way. The caller closes a tab that gave
  /// way before it calls this, so the pane never holds more tabs than its cap.
  mutating func open(requesterKey key: String, id: AppletTabID) {
    if let index = entries.firstIndex(where: { $0.requesterKey == key }) {
      entries[index].phase = .open
      selected = entries[index].id

      return
    }

    entries.append(Entry(id: id, requesterKey: key, phase: .open))
    selected = id
  }

  /// Marks a tab's form resolved. Returns false when the tab is not open.
  @discardableResult
  mutating func resolve(_ id: AppletTabID) -> Bool {
    guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].isOpen else {
      return false
    }

    resolutions += 1
    entries[index].phase = .resolved(order: resolutions)

    return true
  }

  /// Selects a tab. Returns false when there is none with this ID.
  @discardableResult
  mutating func select(_ id: AppletTabID) -> Bool {
    guard entries.contains(where: { $0.id == id }) else { return false }

    selected = id

    return true
  }

  /// Removes a tab. A selected tab that closes hands the selection to the tab that takes its
  /// place, or to the last tab, as a closed tab does elsewhere. Returns the entry that left.
  @discardableResult
  mutating func remove(_ id: AppletTabID) -> Entry? {
    guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }

    let removed = entries.remove(at: index)

    if selected == id {
      selected = entries.isEmpty ? nil : entries[min(index, entries.count - 1)].id
    }

    return removed
  }
}
