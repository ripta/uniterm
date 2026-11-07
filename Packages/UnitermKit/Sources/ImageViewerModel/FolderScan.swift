import Foundation
import SourceAccess
import os

/// What a folder scan reports.
public enum ScanUpdate: Sendable, Equatable {
  /// More images, in the order the disk gave them.
  case batch([ListedImage])

  /// Every image has been reported.
  case finished

  /// Every image, in `sort` order. The scan's own thread sorted them, just before `finished`, so the
  /// main thread need not.
  case ordered(ImageSort, [ListedImage])

  /// The folder could not be read to its end. Batches already reported stand.
  case failed(SourceAccessError)
}

/// How a scan paces itself. Tests shrink the batch and hold the scan between batches.
public struct ScanPace: Sendable {
  public var batchSize: Int

  /// Runs on the scan's own thread before each batch is handed over. A test blocks in it to keep a
  /// scan partial.
  public var beforeBatch: (@Sendable (Int) -> Void)?

  public init(batchSize: Int = 256, beforeBatch: (@Sendable (Int) -> Void)? = nil) {
    self.batchSize = batchSize
    self.beforeBatch = beforeBatch
  }
}

public enum FolderScan {
  /// Scans `folder` on a background thread and reports through the stream. Ending the stream's
  /// consumer stops the scan at its next entry.
  public static func updates(
    of folder: OpenedFolder, supporting types: SupportedImageTypes, sort: ImageSort,
    pace: ScanPace = ScanPace()
  ) -> AsyncStream<ScanUpdate> {
    AsyncStream { continuation in
      let cancelled = OSAllocatedUnfairLock(initialState: false)

      continuation.onTermination = { _ in cancelled.withLock { $0 = true } }

      DispatchQueue.global(qos: .userInitiated).async {
        var batches = 0
        var everything: [ListedImage] = []

        let result = folder.scan(
          supporting: types, batchSize: pace.batchSize,
          isCancelled: { cancelled.withLock { $0 } }
        ) { batch in
          pace.beforeBatch?(batches)
          batches += 1
          everything.append(contentsOf: batch)
          continuation.yield(.batch(batch))
        }

        switch result {
        case .success:
          if !cancelled.withLock({ $0 }) {
            continuation.yield(.ordered(sort, FolderListing.sorted(everything, by: sort)))
          }

          continuation.yield(.finished)
        case .failure(let error): continuation.yield(.failed(error))
        }

        continuation.finish()
      }
    }
  }
}
