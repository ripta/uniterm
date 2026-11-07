import Foundation

/// How far a tab's first load has come, and what it shows or holds meanwhile.
///
/// A tab's history record, its stopped message, and its error page each depend on whether a load
/// began. One value holds them together, so a stopped tab that also began loading, or a stopped
/// tab with no message, cannot be written down.
enum LoadState {
  /// No load began. The history record, when there is one, applies at the first load.
  case idle(history: Data?)

  /// The content process ended or hung, and the tab shows the message that the page stopped. The
  /// page waits for the user's Reload.
  case stopped(LoadErrorPage, history: Data?)

  /// A load began, from the stored address, a restored history, or the user. The error page is
  /// what the tab shows in place of a page it could not load, until the next load or commit. A
  /// refused stored address keeps its history here, for the description and the user's next load.
  case loading(error: LoadErrorPage?, history: Data?)

  /// The history record the tab was given and has not applied yet.
  var history: Data? {
    switch self {
    case .idle(let history), .stopped(_, let history), .loading(_, let history):
      return history
    }
  }

  var errorPage: LoadErrorPage? {
    switch self {
    case .idle:
      return nil

    case .stopped(let page, _):
      return page

    case .loading(let error, _):
      return error
    }
  }

  var isStopped: Bool {
    if case .stopped = self { return true }

    return false
  }

  var hasBegunLoading: Bool {
    if case .loading = self { return true }

    return false
  }

  /// The tab put an explanation in the pane in place of a page.
  func showing(_ page: LoadErrorPage) -> LoadState {
    switch self {
    case .idle(let history), .stopped(_, let history), .loading(_, let history):
      return .loading(error: page, history: history)
    }
  }

  /// The same state with no message over the pane. A stopped tab that clears its message is no
  /// longer stopped.
  func withoutError() -> LoadState {
    switch self {
    case .idle:
      return self

    case .stopped(_, let history):
      return .idle(history: history)

    case .loading(_, let history):
      return .loading(error: nil, history: history)
    }
  }

  /// The same state with the history record dropped.
  func withoutHistory() -> LoadState {
    switch self {
    case .idle:
      return .idle(history: nil)

    case .stopped(let page, _):
      return .stopped(page, history: nil)

    case .loading(let error, _):
      return .loading(error: error, history: nil)
    }
  }
}
