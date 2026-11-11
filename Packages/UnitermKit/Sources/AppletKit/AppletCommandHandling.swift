import Foundation

/// A command that shared dispatch has checked against the applet's schema. Only the dispatcher
/// makes one, so an applet that takes it knows the name is declared and every argument fits.
public struct ValidatedAppletCommand: Sendable, Equatable {
  public let name: String
  public let arguments: [String: JSONValue]
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
  /// caller that sees an error knows nothing happened.
  func perform(_ command: ValidatedAppletCommand) throws(AppletCommandError) -> JSONValue

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
