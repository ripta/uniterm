import Foundation

/// One command as a caller sends it: the applet type and schema version it was written for, its
/// name, and its arguments.
public struct AppletCommandSubmission: Sendable, Equatable {
  public let appletType: String
  public let schemaVersion: Int
  public let name: String
  public let arguments: JSONValue

  public init(appletType: String, schemaVersion: Int, name: String, arguments: JSONValue) {
    self.appletType = appletType
    self.schemaVersion = schemaVersion
    self.name = name
    self.arguments = arguments
  }
}

/// The shared dispatch every applet command goes through, from a remote caller or an exec driver.
///
/// A submission is checked in a fixed order: the caller's authority, then the applet type and
/// schema version, then the command and its arguments. Only then does it join the queue. The
/// queue delivers in order, a bounded number per main-thread turn, so a flood of commands never
/// holds the main thread. Authority is checked again as each command is delivered, so a grant
/// revoked after the checks leaves no effect.
///
/// Every submission gets exactly one reply.
@MainActor
public final class ControlDispatcher {
  /// Says why the caller may not command the target now, or nil when it may. It is asked at
  /// submission and again at delivery.
  public typealias Authority = @MainActor () -> AppletCommandError?

  public typealias Reply = @MainActor (Result<JSONValue, AppletCommandError>) -> Void

  /// Runs `body` on a later main-thread turn. Tests replace it to step the queue by hand.
  public typealias Scheduler = @MainActor (@escaping @MainActor () -> Void) -> Void

  private struct Entry {
    weak var applet: (any AppletCommandHandling)?
    let command: ValidatedAppletCommand
    let authority: Authority
    let reply: Reply
  }

  public let maximumQueued: Int
  public let deliveriesPerTurn: Int

  private let schedule: Scheduler
  private var queue: [Entry] = []
  private var head = 0
  private var drainScheduled = false

  public init(
    maximumQueued: Int = 256, deliveriesPerTurn: Int = 32,
    schedule: @escaping Scheduler = ControlDispatcher.nextMainTurn
  ) {
    self.maximumQueued = maximumQueued
    self.deliveriesPerTurn = deliveriesPerTurn
    self.schedule = schedule
  }

  public static func nextMainTurn(_ body: @escaping @MainActor () -> Void) {
    DispatchQueue.main.async { MainActor.assumeIsolated(body) }
  }

  /// How many commands wait for delivery.
  public var queuedCount: Int { queue.count - head }

  /// Checks a command and queues it for `applet`. A command that fails a check is answered at
  /// once and never queued.
  public func submit(
    _ submission: AppletCommandSubmission, to applet: any Applet, authority: @escaping Authority,
    reply: @escaping Reply
  ) {
    switch check(submission, for: applet, authority: authority) {
    case .failure(let error):
      reply(.failure(error))

    case .success(let (handler, command)):
      guard queuedCount < maximumQueued else {
        reply(
          .failure(
            AppletCommandError(
              .busy, "\(maximumQueued) commands already wait for this pane. Try again.")))
        return
      }

      queue.append(Entry(applet: handler, command: command, authority: authority, reply: reply))
      scheduleDrain()
    }
  }

  private func check(
    _ submission: AppletCommandSubmission, for applet: any Applet, authority: Authority
  ) -> Result<(any AppletCommandHandling, ValidatedAppletCommand), AppletCommandError> {
    if let refusal = authority() { return .failure(refusal) }

    guard let handler = applet as? any AppletCommandHandling else {
      return .failure(AppletCommandError(.refused, "this pane's applet takes no commands"))
    }

    let schema = handler.commandSchema

    guard submission.appletType == schema.appletType else {
      return .failure(
        AppletCommandError(
          .unsupportedApplet,
          "the pane runs a \(schema.appletType) applet, not \(submission.appletType)"))
    }

    guard submission.schemaVersion == schema.version else {
      return .failure(
        AppletCommandError(
          .unsupportedVersion,
          "the \(schema.appletType) applet takes command schema version \(schema.version), not "
            + "\(submission.schemaVersion). Update the program that sent it, or uniterm."))
    }

    guard let declared = schema.command(named: submission.name) else {
      let names = schema.commands.map(\.name).joined(separator: ", ")

      return .failure(
        AppletCommandError(
          .unknownCommand,
          "the \(schema.appletType) applet has no command \"\(submission.name)\". Its commands "
            + "are \(names.isEmpty ? "none" : names)"))
    }

    let fields: [String: JSONValue]

    switch submission.arguments {
    case .object(let object): fields = object
    case .null: fields = [:]
    default:
      return .failure(AppletCommandError(.badArgument, "the arguments must be an object"))
    }

    do {
      try declared.arguments.validate(fields, at: "the arguments")
    } catch {
      return .failure(error)
    }

    return .success((handler, ValidatedAppletCommand(name: submission.name, arguments: fields)))
  }

  private func scheduleDrain() {
    guard !drainScheduled, queuedCount > 0 else { return }

    drainScheduled = true
    schedule { [weak self] in self?.drain() }
  }

  /// Delivers up to `deliveriesPerTurn` commands, then leaves the rest for a later turn.
  func drain() {
    drainScheduled = false

    var delivered = 0

    while delivered < deliveriesPerTurn, head < queue.count {
      let entry = queue[head]
      head += 1
      delivered += 1

      deliver(entry)
    }

    if head == queue.count {
      queue.removeAll(keepingCapacity: true)
      head = 0
    } else if head > 64, head * 2 > queue.count {
      queue.removeFirst(head)
      head = 0
    }

    scheduleDrain()
  }

  private func deliver(_ entry: Entry) {
    guard let applet = entry.applet else {
      entry.reply(.failure(AppletCommandError(.notFound, "the pane closed")))
      return
    }

    if let refusal = entry.authority() {
      entry.reply(.failure(refusal))
      return
    }

    do {
      entry.reply(.success(try applet.perform(entry.command)))
    } catch {
      entry.reply(.failure(error))
    }
  }
}
