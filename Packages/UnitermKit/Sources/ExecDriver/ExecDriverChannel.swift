import AppletKit
import Darwin
import Foundation
import StatusKit

/// One running exec driver attached to one applet.
///
/// Applet events go to the driver's stdin, and commands from its stdout go through shared dispatch
/// to the applet. The driver's stderr goes to the window history as info, through a producer
/// labelled with the driver, and takes no turn on the status bar. An exit or a protocol failure is
/// a typed warning from the host, never a level read from the driver's own text.
///
/// The channel connects to the applet's event outlet, so the applet's close ends it. Ending takes
/// the driver's authority away at once, and the child is shut down on other threads.
@MainActor
public final class ExecDriverChannel: AppletEventSink {
  /// Why a channel ended.
  public enum End: Sendable, Equatable, CustomStringConvertible {
    /// The pane, the applet, or the user ended it. Nothing is reported.
    case closed

    /// The driver exited. The status is the raw `waitpid` status.
    case exited(Int32)

    /// The driver broke the wire's rules or its bounds.
    case failed(String)

    /// The two sides do not support each other's hello, or the driver refused the app.
    case refused(String)

    public var description: String {
      switch self {
      case .closed:
        return "The driver was stopped."

      case .exited(let status):
        let signal = status & 0x7F

        return signal == 0
          ? "The driver exited with status \((status >> 8) & 0xFF)."
          : "The driver was ended by signal \(signal)."

      case .failed(let reason):
        return "The driver was stopped because \(reason)."

      case .refused(let reason):
        return reason
      }
    }
  }

  /// What a driver asks of its window beyond its own applet. The window answers each one, and
  /// checks the driver's authority itself.
  public enum HostRequest: Sendable, Equatable {
    /// A layout for the driver's subtree, anchored at its own pane.
    case layout(JSONValue)

    /// A command for a member of a group the driver owns.
    case command(pane: UInt64, AppletCommandSubmission)

    /// A read of the clipboard. The reply is `{"text": ...}`, with null for no text.
    case clipboardRead

    /// A write of plain text to the clipboard. The reply is an empty object.
    case clipboardWrite(String)
  }

  /// Answers a host request with one reply. A window that offers none refuses every request.
  public typealias HostHandler = @MainActor (HostRequest, @escaping ControlDispatcher.Reply) -> Void

  public enum Phase: Sendable, Equatable {
    /// The app sent its hello and waits for the driver's.
    case greeting

    /// Both hellos were accepted. Commands and events flow.
    case connected

    case ended(End)
  }

  public private(set) var phase: Phase = .greeting

  private let launch: ExecLaunch
  private let environment: ExecEnvironment
  private weak var applet: (any AppletCommandHandling)?
  private let schema: AppletCommandSchema
  private let dispatcher: ControlDispatcher
  private let authority: ControlDispatcher.Authority
  private let producer: StatusProducer?
  private let onEnd: @MainActor (End) -> Void
  private let killGrace: DispatchTimeInterval
  private let host: HostHandler?

  private var transport: ExecTransport?
  private var exitStatus: Int32?
  private var drainScheduled = false

  /// `authority` is the window's check that this driver still drives the pane. The channel adds
  /// its own: a channel that has ended commands nothing. `host` answers the driver's layout
  /// requests and its commands to other panes, and nil refuses them.
  public init(
    launch: ExecLaunch, environment: ExecEnvironment, applet: any AppletCommandHandling,
    dispatcher: ControlDispatcher, authority: @escaping ControlDispatcher.Authority,
    producer: StatusProducer?, killGrace: DispatchTimeInterval = .seconds(2),
    host: HostHandler? = nil, onEnd: @escaping @MainActor (End) -> Void
  ) {
    self.launch = launch
    self.environment = environment
    self.applet = applet
    schema = applet.commandSchema
    self.dispatcher = dispatcher
    self.authority = authority
    self.producer = producer
    self.killGrace = killGrace
    self.host = host
    self.onEnd = onEnd
  }

  /// The child's process ID while it runs.
  public var pid: pid_t? { transport?.pid }

  public var isConnected: Bool { phase == .connected }

  /// Connects to the applet's outlet, spawns the driver, and sends the app's hello. An applet
  /// whose outlet has closed spawns nothing, and the channel ends at once. A spawn that fails
  /// throws, and the channel ends with no report, since the caller reports it.
  public func start() throws {
    guard transport == nil, !isEnded else { return }

    guard let applet, applet.events.connect(self) else {
      end(.closed)
      return
    }

    let transport: ExecTransport

    do {
      transport = try ExecTransport.spawn(
        arguments: launch.arguments, directory: launch.directory,
        environment: environment.environment(adding: launch.environment), killGrace: killGrace
      ) { [weak self] event in
        DispatchQueue.main.async {
          MainActor.assumeIsolated { self?.handle(event) }
        }
      }
    } catch {
      phase = .ended(.closed)
      applet.events.disconnect(self)
      throw error
    }

    self.transport = transport

    transport.start()
    transport.send(
      ExecWire.frame(
        .hello(
          protocolVersion: ExecProtocol.version, appletType: schema.appletType,
          schemaVersion: schema.version)))
  }

  /// Ends the channel: authority at once, the child on other threads.
  public func close() {
    end(.closed)
  }

  /// Ends the channel at quit, and waits until `deadline` at most for the driver to end on
  /// SIGTERM before its group gets SIGKILL. Close every channel first, so their SIGTERMs go out
  /// together and the waits overlap.
  public func finishForQuit(by deadline: Date) {
    let transport = self.transport

    end(.closed)
    transport?.finishForQuit(by: deadline)
  }

  // MARK: AppletEventSink

  /// An event goes to the driver only once both hellos are accepted. Before that, and after the
  /// channel ends, it goes nowhere. An event the schema does not declare, or whose data does not
  /// fit its schema, is the applet's mistake and is not sent.
  public func deliver(event name: String, data: JSONValue) {
    guard isConnected, let declared = schema.event(named: name) else { return }

    guard case .object(let fields) = data,
      (try? declared.arguments.validate(fields, at: "the event")) != nil
    else { return }

    transport?.send(ExecWire.frame(.event(name: name, data: data)))
  }

  public func outletClosed() {
    end(.closed)
  }

  // MARK: Transport

  private func handle(_ event: ExecTransportEvent) {
    switch event {
    case .messagesReady:
      drain()

    case .stderrReady:
      recordStderr()

    case .failed(let failure):
      end(.failed(failure.description))

    case .exited(let status):
      exitStatus = status
      drain()
    }
  }

  /// Handles at most `framesPerTurn` messages, then yields the main thread. Window shortcuts and
  /// every other event run between turns, however fast the driver writes.
  private func drain() {
    drainScheduled = false

    guard let transport, !isEnded else { return }

    let (messages, remaining) = transport.takeMessages(limit: ExecProtocol.framesPerTurn)

    for message in messages {
      guard !isEnded else { return }

      handle(message)
    }

    if remaining {
      scheduleDrain()
    } else if let exitStatus {
      end(.exited(exitStatus))
    }
  }

  private func scheduleDrain() {
    guard !drainScheduled else { return }

    drainScheduled = true

    DispatchQueue.main.async { [weak self] in
      MainActor.assumeIsolated { self?.drain() }
    }
  }

  private var isEnded: Bool {
    if case .ended = phase { return true }

    return false
  }

  private func handle(_ message: ExecDriverMessage) {
    switch (phase, message) {
    case (.greeting, .hello(let version, let type, let schemaVersion)):
      greet(version: version, type: type, schemaVersion: schemaVersion)

    case (.connected, .hello):
      end(.failed("it sent a second hello"))

    case (.greeting, .command), (.greeting, .paneCommand), (.greeting, .layout),
      (.greeting, .clipboardRead), (.greeting, .clipboardWrite):
      end(.failed("it sent a command before its hello"))

    case (.connected, .command(let id, let name, let arguments)):
      run(id: id, name: name, arguments: arguments)

    case (
      .connected, .paneCommand(let id, let pane, let type, let version, let name, let arguments)
    ):
      let submission = AppletCommandSubmission(
        appletType: type, schemaVersion: version, name: name, arguments: arguments)

      ask(.command(pane: pane, submission), id: id)

    case (.connected, .layout(let id, let layout)):
      ask(.layout(layout), id: id)

    case (.connected, .clipboardRead(let id)):
      ask(.clipboardRead, id: id)

    case (.connected, .clipboardWrite(let id, let text)):
      ask(.clipboardWrite(text), id: id)

    case (_, .refusal(let text)):
      end(.refused("The driver refused uniterm: \(StatusText.bounded(text, maximumBytes: 256))"))

    case (.ended, _):
      return
    }
  }

  /// Both sides must support the other. A driver that names another protocol, applet type, or
  /// schema version is told why, and the channel ends before any command runs.
  private func greet(version: Int, type: String, schemaVersion: Int) {
    let refusal: (code: String, text: String)?

    if version != ExecProtocol.version {
      refusal = (
        "unsupported-version",
        "The driver speaks exec protocol \(version), and this uniterm speaks "
          + "\(ExecProtocol.version). Update the driver or uniterm so they match."
      )
    } else if type != schema.appletType {
      refusal = (
        "unsupported-applet",
        "The driver was written for a \(type) applet, and this pane runs \(schema.appletType)."
      )
    } else if schemaVersion != schema.version {
      refusal = (
        "unsupported-version",
        "The driver uses \(type) schema version \(schemaVersion), and this pane takes "
          + "\(schema.version). Update the driver or uniterm so they match."
      )
    } else {
      refusal = nil
    }

    guard let refusal else {
      phase = .connected
      return
    }

    transport?.send(ExecWire.frame(.error(id: nil, code: refusal.code, message: refusal.text)))
    end(.refused(refusal.text))
  }

  private func run(id: JSONValue, name: String, arguments: JSONValue) {
    guard let applet else {
      end(.closed)
      return
    }

    let submission = AppletCommandSubmission(
      appletType: schema.appletType, schemaVersion: schema.version, name: name,
      arguments: arguments)

    dispatcher.submit(
      submission, to: applet,
      authority: { [weak self] in
        guard let self, isConnected else {
          return AppletCommandError(.refused, "the driver no longer drives this pane")
        }

        return authority()
      },
      reply: { [weak self] in self?.answer(id: id, with: $0) })
  }

  /// Hands a request beyond the driver's own applet to the window. The window checks the
  /// driver's authority, and the reply reaches the driver only while the channel is connected.
  private func ask(_ request: HostRequest, id: JSONValue) {
    guard let host else {
      answer(
        id: id,
        with: .failure(AppletCommandError(.refused, "this pane's driver may act only on its pane")))
      return
    }

    host(request) { [weak self] in self?.answer(id: id, with: $0) }
  }

  private func answer(id: JSONValue, with result: Result<JSONValue, AppletCommandError>) {
    guard isConnected else { return }

    switch result {
    case .success(let value):
      transport?.send(ExecWire.frame(.reply(id: id, result: value)))

    case .failure(let error):
      transport?.send(
        ExecWire.frame(.error(id: id, code: error.code.rawValue, message: error.message)))
    }
  }

  private func recordStderr() {
    guard let batch = transport?.stderr.drain(), !batch.isEmpty else { return }

    producer?.record(stderr: batch)
  }

  private func end(_ reason: End) {
    guard !isEnded else { return }

    phase = .ended(reason)
    applet?.events.disconnect(self)
    transport?.close()
    recordStderr()

    if reason != .closed {
      producer?.post(failure: .contentUnavailable, text: reason.description)
    }

    onEnd(reason)
  }
}
