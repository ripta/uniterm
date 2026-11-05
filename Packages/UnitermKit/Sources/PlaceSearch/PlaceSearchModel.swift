import Foundation

/// The state of one place search field, apart from its views.
///
/// The first suggestion is highlighted as soon as it arrives, so Return picks what the user sees
/// highlighted. Return with nothing highlighted picks nothing. The model never guesses a place on
/// its own.
public struct PlaceSearchModel: Equatable {
  public enum Status: Equatable {
    /// The field is empty.
    case idle

    /// A query is out and no answer has come back for it.
    case searching

    /// Suggestions are showing.
    case results

    /// The service found nothing for the query.
    case noMatch

    /// The search failed.
    case failed(PlaceSearchFailure)

    /// The user picked a suggestion and its region is being found.
    case resolving(PlaceSuggestion)
  }

  public private(set) var query = ""
  public private(set) var suggestions: [PlaceSuggestion] = []
  public private(set) var highlighted: Int?
  public private(set) var status = Status.idle

  /// How many suggestions show at once.
  public static let maximumShown = 6

  public init() {}

  public var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

  /// The suggestion Return would pick.
  public var highlightedSuggestion: PlaceSuggestion? {
    highlighted.flatMap { suggestions.indices.contains($0) ? suggestions[$0] : nil }
  }

  /// The line shown under the field, or nil for none.
  public var message: String? {
    switch status {
    case .idle, .searching, .results: return nil
    case .noMatch: return "No places match. Try a city, an address, or a landmark."
    case .failed(let failure): return failure.message
    case .resolving(let suggestion): return "Finding \(suggestion.title)\u{2026}"
    }
  }

  /// Takes the field's new text. Returns true when the searcher should be asked.
  public mutating func setQuery(_ text: String) -> Bool {
    guard text != query else { return false }

    query = text

    guard !trimmedQuery.isEmpty else {
      suggestions = []
      highlighted = nil
      status = .idle
      return false
    }

    status = .searching
    return true
  }

  /// Takes the searcher's answer for the latest query.
  public mutating func receive(_ result: Result<[PlaceSuggestion], PlaceSearchFailure>) {
    guard !trimmedQuery.isEmpty else { return }

    if case .resolving = status { return }

    switch result {
    case .success(let found):
      suggestions = Array(found.prefix(Self.maximumShown))
      highlighted = suggestions.isEmpty ? nil : 0
      status = suggestions.isEmpty ? .noMatch : .results

    case .failure(let failure):
      suggestions = []
      highlighted = nil
      status = .failed(failure)
    }
  }

  /// Moves the highlight by `step`. Returns false when there is nothing to move through, so the
  /// caller may use the key for something else.
  public mutating func move(by step: Int) -> Bool {
    guard !suggestions.isEmpty else { return false }

    let at = highlighted ?? (step > 0 ? -1 : suggestions.count)
    highlighted = min(max(at + step, 0), suggestions.count - 1)
    return true
  }

  /// Highlights the suggestion at `index`, as a click does.
  public mutating func highlight(_ index: Int) {
    guard suggestions.indices.contains(index) else { return }

    highlighted = index
  }

  /// Starts finding the highlighted suggestion's region. Returns it, or nil when none is
  /// highlighted or one is already being found.
  public mutating func pick() -> PlaceSuggestion? {
    if case .resolving = status { return nil }

    guard let suggestion = highlightedSuggestion else { return nil }

    status = .resolving(suggestion)
    return suggestion
  }

  /// Takes the end of a pick that failed. The suggestions stay, so the user can try another.
  public mutating func pickFailed(_ failure: PlaceSearchFailure) {
    status = .failed(failure)
  }

  /// Empties the field.
  public mutating func clear() {
    query = ""
    suggestions = []
    highlighted = nil
    status = .idle
  }
}
