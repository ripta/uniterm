import Foundation
import ProcessInspection
import ScriptWire

/// A connection's binding to a session root: one found through the peer's ancestry at admission,
/// or one the user granted.
public struct ConnectionBinding: Sendable, Equatable {
  public let root: ProcessIdentity
  public let generation: UInt64

  public init(root: ProcessIdentity, generation: UInt64) {
    self.root = root
    self.generation = generation
  }
}

/// One helper's connection to the app, after its hello was accepted.
///
/// The main actor holds a connection to answer its calls. It never blocks on the peer. A reply is
/// queued for the connection's own writer, and the writer may block on a peer that does not read.
/// The queue is bounded by messages and by bytes. A peer that lets it fill is disconnected, so a
/// peer that never reads cannot grow the app's memory.
public final class ScriptConnection: @unchecked Sendable, Identifiable {
  /// How many calls one connection may have waiting for an answer. The reader stops reading until
  /// one is answered, so a peer that floods calls cannot grow the app's queue.
  static let maxInFlight = 8

  /// The most replies that may wait for the writer. A helper runs one call at a time, so a well
  /// behaved one never has more than one waiting.
  static let maxQueuedMessages = 64

  /// The most bytes that may wait for the writer. It holds sixteen of the largest replies.
  static let maxQueuedBytes = 1 << 20

  public let id: UInt64
  public let peer: ScriptPeer

  /// The peer's start time, read when the connection was admitted. Used to detect PID reuse.
  public let peerStartTime: Int

  /// The session root this connection is bound to. Nil when the connection is unbound.
  private(set) var binding: ConnectionBinding?

  let socket: FramedSocket
  let slots = DispatchSemaphore(value: maxInFlight)

  private let writer: DispatchQueue
  private let lock = NSLock()
  private let onOverflow: @Sendable (ScriptConnection) -> Void
  private var closed = false
  private var queuedMessages = 0
  private var queuedBytes = 0

  init(
    id: UInt64, peer: ScriptPeer, peerStartTime: Int, socket: FramedSocket,
    binding: ConnectionBinding? = nil,
    onOverflow: @escaping @Sendable (ScriptConnection) -> Void = { _ in }
  ) {
    self.id = id
    self.peer = peer
    self.peerStartTime = peerStartTime
    self.socket = socket
    self.binding = binding
    self.onOverflow = onOverflow
    self.writer = DispatchQueue(label: "uniterm.script.writer.\(id)")
  }

  /// True when the connection is bound to a validated session root.
  public var isBound: Bool { binding != nil }

  /// Lets the connection act for the session `root` started, while that root keeps `generation`.
  /// Each call checks the binding again before it runs.
  @MainActor
  func bind(to root: ProcessIdentity, generation: UInt64) {
    binding = ConnectionBinding(root: root, generation: generation)
  }

  /// Takes the connection's binding away, so its calls are refused again.
  @MainActor
  func unbind() {
    binding = nil
  }

  /// Validates that the connection's binding is still valid. Returns false when the peer process is
  /// no longer running with the same identity, or the session root is no longer recorded with the
  /// same generation.
  @MainActor
  public func validateBinding(registry: SessionRootRegistry) -> Bool {
    guard let binding else { return false }
    guard ProcessInspection.isRunning(pid: peer.pid, started: peerStartTime) else { return false }
    guard peerGenerationHolds else { return false }
    guard let recordedGeneration = registry.sessionGeneration(for: binding.root) else {
      return false
    }
    return recordedGeneration == binding.generation
  }

  /// True while the process on the other end is the one the connection admitted, running the
  /// executable it ran then. The kernel gives a process a new ID version when it starts another
  /// executable, and a reused process ID comes with a new version too. A forked child that took
  /// over the socket has another process ID. Any of these, a closed connection, or a token that
  /// cannot be read, makes it false.
  ///
  /// The token is read from the socket when asked, so a call that arrives after an exec is refused
  /// though the peer sent it before.
  public var peerGenerationHolds: Bool {
    guard let admitted = peer.token, !isClosed,
      let live = ScriptPeer.liveToken(descriptor: socket.rawDescriptor)
    else { return false }

    return live.pid == admitted.pid && live.pidVersion == admitted.pidVersion
  }

  /// What waits for the writer now, for the tests.
  var queued: (messages: Int, bytes: Int) {
    lock.lock()
    defer { lock.unlock() }

    return (queuedMessages, queuedBytes)
  }

  var isClosed: Bool {
    lock.lock()
    defer { lock.unlock() }

    return closed
  }

  /// Answers a call. Safe from any thread, and never blocks the caller.
  public func reply(id: UInt32, result: ScriptResult) {
    slots.signal()
    send(.reply(id: id, result: result))
  }

  /// Queues a message for the peer. A message that would pass either bound ends the connection
  /// instead, since the peer has stopped reading. Nothing waits in the queue after that.
  func send(_ message: ScriptAppMessage) {
    let frame = message.frame()

    lock.lock()

    guard !closed else {
      lock.unlock()

      return
    }

    guard queuedMessages < Self.maxQueuedMessages,
      queuedBytes + frame.count <= Self.maxQueuedBytes
    else {
      lock.unlock()

      close()
      onOverflow(self)

      return
    }

    queuedMessages += 1
    queuedBytes += frame.count
    lock.unlock()

    writer.async { [self] in
      defer {
        lock.lock()
        queuedMessages -= 1
        queuedBytes -= frame.count
        lock.unlock()
      }

      guard !isClosed else { return }

      do {
        try socket.send(frame)
      } catch {
        close()
      }
    }
  }

  /// Closes the connection once every message queued before this call has been written. A refusal
  /// uses it, so the peer reads the reason before the socket goes.
  func closeAfterSending() {
    writer.async { [self] in close() }
  }

  /// Ends the connection for both sides. Safe to call twice.
  public func close() {
    lock.lock()

    let wasOpen = !closed

    closed = true
    lock.unlock()

    guard wasOpen else { return }

    socket.shutdownAndClose()

    for _ in 0..<Self.maxInFlight {
      slots.signal()
    }
  }
}
