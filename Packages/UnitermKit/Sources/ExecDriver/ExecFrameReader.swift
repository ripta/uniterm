import Foundation

/// Splits a driver's stdout into LF-terminated lines.
///
/// The bound applies as bytes arrive: a line that grows past the limit is refused before the rest
/// of it is read, so a driver that never writes a newline cannot make the reader hold more than
/// the limit.
public struct ExecFrameReader: Sendable {
  public let maximumFrameBytes: Int
  private var partial: [UInt8] = []

  public init(maximumFrameBytes: Int = ExecProtocol.maxFrameBytes) {
    self.maximumFrameBytes = maximumFrameBytes
  }

  /// The bytes of a line not yet ended.
  public var pendingBytes: Int { partial.count }

  /// Takes the next bytes, and returns the lines they complete, without their newlines.
  public mutating func feed(_ bytes: some Collection<UInt8>) throws(ExecWireError) -> [Data] {
    var lines: [Data] = []
    var rest = bytes[...]

    while let newline = rest.firstIndex(of: 0x0A) {
      let piece = rest[..<newline]

      guard partial.count + piece.count <= maximumFrameBytes else { throw .frameTooLong }

      partial.append(contentsOf: piece)
      lines.append(Data(partial))
      partial.removeAll(keepingCapacity: true)
      rest = rest[rest.index(after: newline)...]
    }

    guard partial.count + rest.count <= maximumFrameBytes else { throw .frameTooLong }

    partial.append(contentsOf: rest)

    return lines
  }

  /// The driver's output ended. A line left open is a partial frame, which closes the channel.
  public func finish() throws(ExecWireError) {
    guard partial.isEmpty else { throw .partialFrameAtEOF }
  }
}
