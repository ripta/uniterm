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
///
/// A read can end partway through a line, since a driver may write one line in pieces. The
/// unfinished tail is held and joined to the next chunk. It is let go as a line once its newline
/// arrives, once it reaches the line bound, once `quietPeriod` passes with nothing added to it, or
/// when the stream ends. So a lone partial line, such as a progress note, still shows.
public final class StderrIngress: @unchecked Sendable {
  private let maximumLines: Int
  private let maximumBytes: Int
  private let maximumLineBytes: Int
  private let maximumChunkBytes: Int
  private let maximumChunkLines: Int
  private let quietPeriod: Duration
  private let now: @Sendable () -> ContinuousClock.Instant
  private let lock = NSLock()
  private var batch = StderrBatch()
  private var bytes = 0

  /// The unfinished last line, and when text was last added to it.
  private var tail = ""
  private var tailChanged: ContinuousClock.Instant?

  public init(
    maximumLines: Int = 64, maximumBytes: Int = 16 * 1024, maximumLineBytes: Int = 512,
    quietPeriod: Duration = .milliseconds(250),
    now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
  ) {
    self.maximumLines = maximumLines
    self.maximumBytes = maximumBytes
    self.maximumLineBytes = maximumLineBytes
    self.quietPeriod = quietPeriod
    self.now = now
    maximumChunkBytes = maximumBytes * 4
    maximumChunkLines = maximumLines * 4
  }

  /// Takes a chunk of stderr. Returns true when the caller schedules one hop to the main thread:
  /// the batch went from empty to holding lines, or a tail started while nothing else was held.
  /// After each drain, the drainer drains again at `tailDeadline` while a tail is held.
  ///
  /// A chunk is read only up to `maximumChunkBytes` and `maximumChunkLines`. The rest is counted
  /// as dropped. This keeps the work under the lock, which the drain waits on, to a fixed amount
  /// whatever the reader hands over.
  @discardableResult
  public func offer(_ chunk: String) -> Bool {
    lock.lock()
    let held = tail
    tail = ""
    lock.unlock()

    let joined = held + chunk
    let utf8 = joined.utf8
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
    var pieces = head.split(omittingEmptySubsequences: false) {
      $0 == "\n" || $0 == "\r" || $0 == "\r\n"
    }

    // The last piece has no newline after it yet. A chunk cut at the bound has lost the rest of
    // that line, so its last piece is kept as it is.
    var unfinished = ""

    if utf8.count <= maximumChunkBytes, let last = pieces.last {
      pieces.removeLast()

      if last.utf8.count < maximumLineBytes {
        unfinished = String(last)
      } else {
        pieces.append(last)
      }
    }

    for piece in pieces where !piece.isEmpty {
      guard lines.count < maximumChunkLines else {
        dropped += 1
        continue
      }

      let line = StatusText.bounded(String(piece), maximumBytes: maximumLineBytes)

      if !line.isEmpty { lines.append(line) }
    }

    lock.lock()
    defer { lock.unlock() }

    // Another reader's offer may have stored a tail since this one took it. It is let go as a
    // line, never overwritten.
    if !tail.isEmpty { releaseTail() }

    let batchWasEmpty = batch.isEmpty

    append(lines, dropped: dropped)
    tail = unfinished
    tailChanged = unfinished.isEmpty ? nil : now()

    // A hop is already due when the batch held something, and a drain that saw a held tail
    // already watches its deadline. A new tail with nothing else needs a hop of its own.
    let startedTail = held.isEmpty && !unfinished.isEmpty

    return (batchWasEmpty && !batch.isEmpty) || (batch.isEmpty && startedTail)
  }

  /// When the held tail is let go if nothing is added to it, or nil when none is held. The drainer
  /// drains again then.
  public var tailDeadline: ContinuousClock.Instant? {
    lock.lock()
    defer { lock.unlock() }

    return tailChanged.map { $0 + quietPeriod }
  }

  /// The stream ended, so a held tail is a whole line. Returns true when the ingress went from
  /// holding nothing to holding a line.
  @discardableResult
  public func finish() -> Bool {
    lock.lock()
    defer { lock.unlock() }

    let wasEmpty = batch.isEmpty
    releaseTail()

    return wasEmpty && !batch.isEmpty
  }

  /// Takes what the reader buffered and empties the buffer. A tail held for `quietPeriod` with
  /// nothing added comes along as a line.
  public func drain() -> StderrBatch {
    lock.lock()
    defer { lock.unlock() }

    if let changed = tailChanged, now() >= changed + quietPeriod {
      releaseTail()
    }

    let result = batch
    batch = StderrBatch()
    bytes = 0
    return result
  }

  /// Moves the held tail into the batch. The caller holds the lock.
  private func releaseTail() {
    let line = StatusText.bounded(tail, maximumBytes: maximumLineBytes)

    tail = ""
    tailChanged = nil

    if !line.isEmpty { append([line], dropped: 0) }
  }

  /// Adds lines to the batch within its bounds. The caller holds the lock.
  private func append(_ lines: [String], dropped: Int) {
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
  }
}
