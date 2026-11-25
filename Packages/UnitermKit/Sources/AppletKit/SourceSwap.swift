import Foundation

/// A viewer's swap to a file the user picked or dropped, waiting for the file's start directory.
///
/// The start directory needs a `stat`, which can wait as long as the file's mount takes to answer.
/// So it runs off the main thread, and the swap lands when it answers. A later swap supersedes one
/// still waiting, so the last file the user chose is the one the pane shows. `cancel()` drops a swap
/// still waiting, as a closing pane does.
@MainActor
public final class SourceSwap {
  /// The swap in flight, until it lands or is superseded.
  public private(set) var pending: Task<Void, Never>?

  private var generation = 0

  /// Learns a file's start directory. Tests replace it to hold the answer.
  var startDirectory: @Sendable (URL) async -> String = SourceStartDirectory.resolving

  public init() {}

  /// Learns `file`'s start directory, then calls `replace` with both, unless a later swap or a
  /// cancel came first.
  @discardableResult
  public func start(
    _ file: URL, then replace: @escaping @MainActor (URL, String) -> Void
  ) -> Task<Void, Never> {
    generation += 1

    let current = generation
    let resolve = startDirectory

    let task = Task { @MainActor [weak self] in
      let directory = await resolve(file)

      guard let self, current == self.generation else { return }

      self.pending = nil
      replace(file, directory)
    }

    pending = task

    return task
  }

  /// Drops any swap still waiting.
  public func cancel() {
    generation += 1
    pending = nil
  }
}

extension SourceStartDirectory {
  /// `of(_:)`, off the main thread.
  @concurrent
  public static func resolving(_ url: URL) async -> String {
    of(url)
  }
}
