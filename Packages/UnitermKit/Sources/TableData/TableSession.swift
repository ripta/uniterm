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
  public private(set) var selection = RowSelection.all(count: 0)

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

  /// Stops the load, gives the budget back, and drops the rows.
  public func close() {
    reset()
    phase = .idle
    query = TableQuery()
  }

  private func reset() {
    generation += 1
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
