import Foundation

/// Lines of drained stderr text, coalesced, with a count of what did not fit.
public struct StderrBatch: Sendable, Equatable {
  public struct Line: Sendable, Equatable {
    public var text: String
    public var count: Int
  }

  public var lines: [Line] = []
  public var dropped = 0

  public var isEmpty: Bool { lines.isEmpty && dropped == 0 }
}

/// The bounded buffer between a driver's stderr reader and the main thread.
///
/// The reader calls `offer` from its own thread. The host drains on the main thread after a hop.
/// Both sides hold the lock only to move a few bounded values, so neither waits on outside work.
/// Text is sanitized and cut before it takes the lock. Identical neighbors share one line with a
/// count. A line past the line or byte bound is dropped and counted, whatever it says. The
/// ingress never reads a word of the text to pick a level.
public final class StderrIngress: @unchecked Sendable {
  private let maximumLines: Int
  private let maximumBytes: Int
  private let maximumLineBytes: Int
  private let maximumChunkBytes: Int
  private let maximumChunkLines: Int
  private let lock = NSLock()
  private var batch = StderrBatch()
  private var bytes = 0

  public init(maximumLines: Int = 64, maximumBytes: Int = 16 * 1024, maximumLineBytes: Int = 512) {
    self.maximumLines = maximumLines
    self.maximumBytes = maximumBytes
    self.maximumLineBytes = maximumLineBytes
    maximumChunkBytes = maximumBytes * 4
    maximumChunkLines = maximumLines * 4
  }

  /// Takes a chunk of stderr. Returns true when the buffer went from empty to holding something,
  /// which is when the caller schedules one hop to the main thread.
  ///
  /// A chunk is read only up to `maximumChunkBytes` and `maximumChunkLines`. The rest is counted
  /// as dropped. This keeps the work under the lock, which the drain waits on, to a fixed amount
  /// whatever the reader hands over.
  @discardableResult
  public func offer(_ chunk: String) -> Bool {
    let utf8 = chunk.utf8
    let head = String(decoding: utf8.prefix(maximumChunkBytes), as: UTF8.self)
    var dropped = 0

    if utf8.count > maximumChunkBytes {
      let newlines = utf8.dropFirst(maximumChunkBytes).reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
      let unterminated = utf8.last != 0x0A ? 1 : 0
      let lastKept = utf8[utf8.index(utf8.startIndex, offsetBy: maximumChunkBytes - 1)]
      let continued = lastKept != 0x0A ? 1 : 0
      dropped += max(0, newlines + unterminated - continued)
    }

    var lines: [String] = []

    for piece in head.split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) {
      guard lines.count < maximumChunkLines else {
        dropped += 1
        continue
      }

      let line = StatusText.bounded(String(piece), maximumBytes: maximumLineBytes)

      if !line.isEmpty { lines.append(line) }
    }

    guard !lines.isEmpty || dropped > 0 else { return false }

    lock.lock()
    defer { lock.unlock() }

    let wasEmpty = batch.isEmpty
    batch.dropped += dropped

    for line in lines {
      if let last = batch.lines.indices.last, batch.lines[last].text == line {
        batch.lines[last].count += 1
        continue
      }

      let size = line.utf8.count

      guard batch.lines.count < maximumLines, bytes + size <= maximumBytes else {
        batch.dropped += 1
        continue
      }

      batch.lines.append(StderrBatch.Line(text: line, count: 1))
      bytes += size
    }

    return wasEmpty
  }

  /// Takes what the reader buffered and empties the buffer.
  public func drain() -> StderrBatch {
    lock.lock()
    defer { lock.unlock() }

    let result = batch
    batch = StderrBatch()
    bytes = 0
    return result
  }
}
