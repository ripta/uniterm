import Foundation
import SourceAccess

/// A command that shared dispatch has checked against the applet's schema. Only the dispatcher
/// makes one, so an applet that takes it knows the name is declared and every argument fits.
public struct ValidatedAppletCommand: Sendable, Equatable {
  public let name: String

  /// The arguments as the caller sent them, except that a path-typed argument reads as null.
  public let arguments: [String: JSONValue]

  /// What the host opened for each path-typed argument, by the argument's name. A nested one is
  /// named `field.inner` or `field[0]`. The applet gets the opened file or folder and never the
  /// path the caller wrote.
  public let opened: [String: OpenedPath]

  /// What the caller may be told. An applet whose pane shows a user's file checks it before it
  /// puts anything from that file into a reply.
  public let access: ReadAccess

  init(
    name: String, arguments: [String: JSONValue], opened: [String: OpenedPath] = [:],
    access: ReadAccess = .none
  ) {
    self.name = name
    self.arguments = arguments
    self.opened = opened
    self.access = access
  }
}

/// An applet that shows a file or folder the user chose, and says which path it is.
///
/// The host asks before it tells a controller about the pane. A controller whose read scope does
/// not hold the path is told nothing that comes from the file: not its name, its folder, or what
/// is in it.
@MainActor
public protocol UserFileSourcing: Applet {
  /// The path of the file or folder the pane shows, or nil when it shows none. The host tells
  /// content a controller sent apart by the folder it waits in, and shows that to the controller.
  var userFileSource: String? { get }
}

/// How an applet answers one command.
public enum AppletCommandReply {
  /// The reply is ready now.
  case immediate(JSONValue)

  /// The reply comes later, through the pending reply the applet holds. See `PendingReply`.
  case pending(PendingReply)
}

/// A reply an applet completes later, for a command that waits on something, such as a condition
/// that has not yet come true.
///
/// Only a command with no effect may pend. A pending reply can fail without the applet's say, when
/// the caller loses its authority, the run ends, the caller disconnects, the pane closes, or the
/// window holds too many. A failed pending reply tells the caller that nothing ran, so a command
/// that changed anything must answer at once, where a thrown error keeps the same promise.
///
/// The applet keeps the reply it returns and settles it once, with `complete` or `fail`. Before
/// `complete` reaches the caller, the dispatcher checks the caller's authority again. When the
/// dispatcher fails the reply first, it calls `onCancel`, and the applet drops whatever it held to
/// complete the reply. A settle after that does nothing and returns false.
@MainActor
public final class PendingReply {
  /// Called once, when the dispatcher fails the reply before the applet settled it.
  public var onCancel: (@MainActor () -> Void)?

  public private(set) var isSettled = false

  private var sink: (@MainActor (Result<JSONValue, AppletCommandError>) -> Void)?
  private var early: Result<JSONValue, AppletCommandError>?

  public init() {}

  /// Answers the command. Returns false when the reply was already settled.
  @discardableResult
  public func complete(_ value: JSONValue) -> Bool {
    settle(.success(value))
  }

  /// Fails the command, which means nothing ran. Returns false when the reply was already settled.
  @discardableResult
  public func fail(_ error: AppletCommandError) -> Bool {
    settle(.failure(error))
  }

  /// Joins the reply to its caller. An applet that settled before this point, inside `perform`,
  /// has its answer delivered now.
  func attach(_ sink: @escaping @MainActor (Result<JSONValue, AppletCommandError>) -> Void) {
    self.sink = sink

    if let early {
      self.early = nil
      sink(early)
    }
  }

  /// The dispatcher's own failure: it settles the reply and tells the applet to let go.
  func cancel(_ error: AppletCommandError) {
    guard !isSettled else { return }

    let release = onCancel

    settle(.failure(error))
    release?()
  }

  @discardableResult
  private func settle(_ result: Result<JSONValue, AppletCommandError>) -> Bool {
    guard !isSettled else { return false }

    isSettled = true
    onCancel = nil

    if let sink {
      self.sink = nil
      sink(result)
    } else {
      early = result
    }

    return true
  }
}

/// The applet contract's command and event hook. An applet that adopts it publishes its command
/// and event schemas, runs the commands shared dispatch delivers, and emits its events through its
/// outlet. An applet that does not adopt it refuses every command.
///
/// Remote callers and an attached exec driver reach the applet only through this hook, after the
/// same authorization, type and version check, argument validation, and serialized delivery.
@MainActor
public protocol AppletCommandHandling: Applet {
  var commandSchema: AppletCommandSchema { get }

  /// Runs one command and returns its reply. A thrown error must leave the applet unchanged, so a
  /// caller that sees an error knows nothing happened. A command with no effect may return a
  /// pending reply instead. See `PendingReply`.
  func perform(_ command: ValidatedAppletCommand) throws(AppletCommandError) -> AppletCommandReply

  /// Where the applet emits its events. The applet owns it, and closes it when it closes.
  var events: AppletEventOutlet { get }
}

/// Takes the events an applet emits. An attached exec driver is the only sink, since remote
/// callers receive no events.
@MainActor
public protocol AppletEventSink: AnyObject {
  func deliver(event name: String, data: JSONValue)

  /// The applet closed its outlet. The sink ends what it attached.
  func outletClosed()
}

/// The one place an applet emits events. With no sink connected, an event goes nowhere and nothing
/// is kept, so an applet that emits with no driver attached never grows a queue.
///
/// The applet closes the outlet when it closes. Closing ends the connected sink, which is how an
/// attached driver's child is shut down as part of the applet's own cleanup.
@MainActor
public final class AppletEventOutlet {
  private var sink: (any AppletEventSink)?
  public private(set) var isClosed = false

  /// Called when a sink has finished attaching and now receives events, as when a driver's hello
  /// is accepted. An applet that sends an event only when its state changes uses it to send the
  /// current state to the sink that just arrived.
  public var onAttached: (@MainActor () -> Void)?

  public init() {}

  public var isConnected: Bool { sink != nil }

  public func emit(_ name: String, _ data: JSONValue = .object([:])) {
    sink?.deliver(event: name, data: data)
  }

  /// Connects a sink in place of any other. Returns false once the outlet is closed.
  @discardableResult
  public func connect(_ sink: any AppletEventSink) -> Bool {
    guard !isClosed else { return false }

    self.sink = sink
    return true
  }

  /// The connected sink says it now receives events.
  public func sinkAttached(_ sink: any AppletEventSink) {
    guard self.sink === sink, !isClosed else { return }

    onAttached?()
  }

  /// Lets go of `sink` when it is the one connected.
  public func disconnect(_ sink: any AppletEventSink) {
    if self.sink === sink { self.sink = nil }
  }

  public func close() {
    guard !isClosed else { return }

    isClosed = true

    let ending = sink
    sink = nil
    ending?.outletClosed()
  }

  isolated deinit {
    sink?.outletClosed()
  }
}
