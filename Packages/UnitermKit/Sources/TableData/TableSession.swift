import Foundation

/// One pane's table: the load, the rows it holds, and the sort and filter over them.
///
/// The session runs on the main actor and does its work elsewhere. The load parses off the main
/// thread. Sorting and filtering run off it too, on an immutable snapshot, and a newer request
/// cancels an older one. The view reads `snapshot` and `selection`, and the session calls
/// `onChange` after either moves.
///
/// While rows arrive under a sort or filter, the view keeps the last finished result. New rows join
/// it only when a run over the newer snapshot ends, so the rows on screen are never out of order.
@MainActor
public final class TableSession {
  public enum Phase: Equatable {
    case idle
    case loading
    case loaded
    case stoppedAtBudget
    case stoppedLowMemory
    case failed(TableLoadError)
  }

  public private(set) var phase = Phase.idle
  public private(set) var snapshot = TableSnapshot.empty
  public private(set) var progress = LoadProgress()

  /// The rows to show.
  public private(set) var selection = RowSelection.all(count: 0) {
    didSet {
      if oldValue != selection { restartSearch() }
    }
  }

  /// The text the find bar searches for. It is apart from the filter. The filter decides which rows
  /// show, and the find query marks cells among the rows that show.
  public private(set) var findQuery = ""

  /// The cells the find query matched among the rows shown. Empty while a search runs.
  public private(set) var matches = SearchMatches.none

  /// The match the user stands on, as an index into `matches`.
  public private(set) var currentMatch: Int?

  /// True while a search runs over the rows shown.
  public private(set) var isSearching = false

  /// Counts the times the current match moved to a new place, so a view can scroll to it once.
  public private(set) var matchRevision = 0

  /// True when the last sort did not get the memory it needed. The rows then show in file order.
  public private(set) var sortSkipped = false

  /// The sort and filter the user asked for. A restored query shows here from the start, and takes
  /// effect once the load ends.
  public private(set) var query = TableQuery()

  public var onChange: (() -> Void)?

  private let budget: TableBudget
  private let pageTarget: Int
  private var lease: TableBudget.Lease
  private var loadTask: Task<Void, Never>?
  private var evaluation: Task<Void, Never>?
  private var evaluationIsStale = false
  private var restoredQueryWaits = false
  private var generation = 0
  private var searchTask: Task<Void, Never>?
  private var searchSequence = 0
  private var revealOnCompletion = false

  /// Where the next search puts the current match, as a row of the file and a column. The cell
  /// itself when it still matches. Otherwise the first match after it.
  private var searchAnchor = (row: 0, column: 0)

  /// The rows `matches` was found in, to turn a match back into a row of the file.
  private var matchSelection = RowSelection.all(count: 0)

  /// The least time between two sorts or filters of a growing table.
  private static let evaluationInterval = Duration.milliseconds(250)

  public init(budget: TableBudget = .shared, pageTarget: Int = TableLoader.defaultPageTarget) {
    self.budget = budget
    self.pageTarget = pageTarget
    lease = budget.makeLease()
  }

  isolated deinit {
    loadTask?.cancel()
    evaluation?.cancel()
    searchTask?.cancel()
  }

  /// How a cell stands in the find: part of a match, the match the user stands on, or neither. The
  /// row is a position among the rows shown.
  public func matchState(row: Int, column: Int) -> MatchState {
    guard matches.contains(row: row, column: column) else { return .none }

    if let currentMatch, matches.position(at: currentMatch) == (row, column) { return .current }

    return .match
  }

  public enum MatchState: Sendable {
    case none
    case match
    case current
  }

  /// Rows the query shows.
  public var visibleCount: Int { selection.count }

  /// Replaces whatever the session holds with the source. The previous load stops. A restored query
  /// waits for the load to end, and an absent column in it is dropped then.
  public func load(_ source: TableSource, restoring restored: TableQuery? = nil) {
    reset()

    query = restored ?? TableQuery()
    restoredQueryWaits = restored != nil
    phase = .loading

    let (stream, continuation) = AsyncStream.makeStream(of: LoadEvent.self)
    let lease = self.lease
    let target = pageTarget
    let started = generation

    loadTask = Task { [weak self] in
      let producer = Task {
        await TableLoader.load(
          source, lease: lease, pageTarget: target, emit: { continuation.yield($0) })
        continuation.finish()
      }

      await withTaskCancellationHandler {
        for await event in stream {
          guard let self, self.generation == started else { break }
          self.receive(event)
        }
      } onCancel: {
        producer.cancel()
      }
    }

    onChange?()
  }

  /// Shows a failure in place of rows, as for a file that could not be found.
  public func fail(_ error: TableLoadError, restoring restored: TableQuery? = nil) {
    reset()

    query = restored ?? TableQuery()
    phase = .failed(error)
    onChange?()
  }

  public func setSort(_ sort: SortSpec?) {
    restoredQueryWaits = false
    query.sort = sort
    queryDidChange()
  }

  /// A click on a column header sorts by it ascending. A second click sorts descending, and a third
  /// clears the sort.
  public func cycleSort(_ column: ColumnIdentity) {
    guard let current = query.sort, current.column == column else {
      setSort(SortSpec(column: column, ascending: true))
      return
    }

    setSort(current.ascending ? SortSpec(column: column, ascending: false) : nil)
  }

  public func setFilter(_ filter: String) {
    restoredQueryWaits = false
    query.filter = filter
    queryDidChange()
  }

  /// Sets the text to find among the rows shown. A newer text cancels the search of an older one.
  /// Typing more of the word, or deleting some, keeps the place. Any other text starts from the
  /// first match.
  public func setFind(_ text: String) {
    guard text != findQuery else { return }

    let lowered = text.lowercased()
    let before = findQuery.lowercased()
    let sameWord =
      !before.isEmpty && !lowered.isEmpty
      && (lowered.hasPrefix(before) || before.hasPrefix(lowered))

    findQuery = text
    restartSearch(keepingPlace: sameWord, reveal: !text.isEmpty)
    onChange?()
  }

  /// Moves to the next or the previous match, and wraps around at the ends. Nothing moves while a
  /// search runs or when nothing matched.
  public func stepMatch(forward: Bool) {
    guard !matches.isEmpty else { return }

    if let current = currentMatch {
      currentMatch = (current + (forward ? 1 : matches.count - 1)) % matches.count
    } else {
      currentMatch = forward ? 0 : matches.count - 1
    }

    matchRevision += 1
    onChange?()
  }

  /// Stops the load, gives the budget back, and drops the rows.
  public func close() {
    reset()
    phase = .idle
    query = TableQuery()
  }

  /// Runs the search again over the rows shown. A change of rows keeps the place. A change of query
  /// keeps it only for the same word. The view scrolls to the current match only when `reveal` is
  /// true, so a reload of rows never moves a view the user scrolled.
  private func restartSearch(keepingPlace: Bool = true, reveal: Bool = false) {
    searchTask?.cancel()
    searchTask = nil
    searchSequence += 1

    if keepingPlace {
      if let current = currentMatch, current < matches.count {
        let place = matches.position(at: current)

        if place.row < matchSelection.count {
          searchAnchor = (matchSelection.row(at: place.row), place.column)
        }
      }
    } else {
      searchAnchor = (0, 0)
    }

    revealOnCompletion = revealOnCompletion || reveal

    matches = .none
    currentMatch = nil

    guard !findQuery.isEmpty else {
      isSearching = false
      return
    }

    isSearching = true

    let snapshot = snapshot
    let selection = selection
    let text = findQuery
    let sequence = searchSequence
    let anchor = searchAnchor

    searchTask = Task { [weak self] in
      let outcome = await Self.search(snapshot, selection, text, anchor)

      guard let self, !Task.isCancelled, self.searchSequence == sequence, let outcome else {
        return
      }

      self.searchTask = nil
      self.isSearching = false
      self.matches = outcome.matches
      self.matchSelection = selection

      if !outcome.matches.isEmpty {
        self.currentMatch = outcome.start
      }

      if self.revealOnCompletion {
        self.revealOnCompletion = false
        self.matchRevision += 1
      }

      self.onChange?()
    }
  }

  @concurrent
  private static func search(
    _ snapshot: TableSnapshot, _ selection: RowSelection, _ text: String,
    _ anchor: (row: Int, column: Int)
  ) async -> (matches: SearchMatches, start: Int)? {
    guard
      let found = TableSearchEngine.run(
        snapshot, selection: selection, query: text, isCancelled: { Task.isCancelled })
    else { return nil }

    return (
      found,
      TableSearchEngine.startIndex(
        in: found, selection: selection, row: anchor.row, column: anchor.column)
    )
  }

  private func reset() {
    generation += 1
    findQuery = ""
    loadTask?.cancel()
    loadTask = nil
    evaluation?.cancel()
    evaluation = nil
    evaluationIsStale = false

    lease.release()
    lease = budget.makeLease()

    snapshot = .empty
    progress = LoadProgress()
    selection = .all(count: 0)
    sortSkipped = false

    revealOnCompletion = false
    matchSelection = .all(count: 0)
    restartSearch(keepingPlace: false)
  }

  private func receive(_ event: LoadEvent) {
    switch event {
    case .snapshot(let next, let latest):
      snapshot = next
      progress = latest
      snapshotDidChange()

    case .finished(let final, let end, let finalProgress):
      progress = finalProgress

      switch end {
      case .completed:
        phase = .loaded
        snapshot = final

      case .stoppedAtBudget:
        phase = .stoppedAtBudget
        snapshot = final

      case .stoppedLowMemory:
        phase = .stoppedLowMemory
        snapshot = final

      case .failed(let error):
        phase = .failed(error)
        snapshot = .empty

      case .cancelled:
        return
      }

      if case .failed = phase {
        // A failed load keeps the stored query, so a save does not lose it.
      } else {
        applyRestoredQuery()
      }

      snapshotDidChange()
    }
  }

  /// Drops a stored sort whose column the file does not have, and lets the query take effect.
  private func applyRestoredQuery() {
    restoredQueryWaits = false

    if let sort = query.sort, !snapshot.columns.contains(where: { $0.identity == sort.column }) {
      query.sort = nil
    }
  }

  private func snapshotDidChange() {
    if query.isEmpty || restoredQueryWaits {
      selection = .all(count: snapshot.rowCount)
      sortSkipped = false
      onChange?()
      return
    }

    if evaluation == nil {
      startEvaluation()
    } else {
      evaluationIsStale = true
    }

    onChange?()
  }

  private func queryDidChange() {
    evaluation?.cancel()
    evaluation = nil
    evaluationIsStale = false

    if query.isEmpty {
      selection = .all(count: snapshot.rowCount)
      sortSkipped = false
      onChange?()
      return
    }

    startEvaluation()
    onChange?()
  }

  private func startEvaluation() {
    let snapshot = snapshot
    let query = query
    let started = generation
    let lease = lease

    evaluation = Task { [weak self] in
      let outcome = await Self.evaluate(snapshot, query, lease)

      guard let self, !Task.isCancelled, self.generation == started else { return }

      if case .done(let result, let skipped) = outcome {
        self.selection = result
        self.sortSkipped = skipped
      }

      self.evaluation = nil

      if self.evaluationIsStale {
        self.evaluationIsStale = false

        try? await Task.sleep(for: Self.evaluationInterval)

        if self.evaluation == nil, !Task.isCancelled, self.generation == started {
          self.startEvaluation()
        }
      }

      self.onChange?()
    }
  }

  @concurrent
  private static func evaluate(
    _ snapshot: TableSnapshot, _ query: TableQuery, _ lease: TableBudget.Lease
  ) async -> QueryOutcome {
    TableQueryEngine.run(
      snapshot, query: query, isCancelled: { Task.isCancelled }, memory: SortMemory(lease: lease))
  }
}
