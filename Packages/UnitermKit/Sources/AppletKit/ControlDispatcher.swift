import Foundation
import SourceAccess

/// One command as a caller sends it: the applet type and schema version it was written for, its
/// name, and its arguments.
public struct AppletCommandSubmission: Sendable, Equatable {
  public let appletType: String
  public let schemaVersion: AppletSchemaVersion
  public let name: String
  public let arguments: JSONValue

  public init(
    appletType: String, schemaVersion: AppletSchemaVersion, name: String, arguments: JSONValue
  ) {
    self.appletType = appletType
    self.schemaVersion = schemaVersion
    self.name = name
    self.arguments = arguments
  }
}

/// What a caller brings to a command that reads: the paths it named, already opened inside its read
/// scope, and the access it holds now.
///
/// The opens happen before the command is submitted and off the main thread, since a path may sit
/// on a slow volume. The dispatcher asks `access` again as it delivers the command, and checks every
/// opened descriptor against it, so a grant that ended while the command waited leaves no read.
public struct CommandReads {
  /// The result of the scoped open for each path-typed argument, by the argument's name.
  public let opened: [String: Result<OpenedPath, ScopedOpenError>]

  /// What the caller may read and see right now.
  public let access: @MainActor () -> ReadAccess

  public init(
    opened: [String: Result<OpenedPath, ScopedOpenError>] = [:],
    access: @escaping @MainActor () -> ReadAccess
  ) {
    self.opened = opened
    self.access = access
  }

  /// A caller with no power: it reads nothing and sees no user's file.
  public static var none: CommandReads { CommandReads(access: { .none }) }
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
///
/// An applet may answer a command with a pending reply, which it completes later. The dispatcher
/// holds the reply and the caller's authority. It checks the authority again before the reply
/// completes. It fails the reply when the window says the authority may have ended, through
/// `revalidatePending`, and when the pane closes, through `failAllPending`. It holds at most
/// `maximumPending` pending replies, one count for the whole window, and fails the rest as busy.
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
    let opened: [String: Result<OpenedPath, ScopedOpenError>]
    let access: @MainActor () -> ReadAccess
    let authority: Authority
    let reply: Reply
  }

  private struct PendingEntry {
    weak var applet: (any AppletCommandHandling)?
    let reply: PendingReply
    let authority: Authority
    let answer: Reply
  }

  public let maximumQueued: Int
  public let deliveriesPerTurn: Int
  public let maximumPending: Int

  /// Called when an applet breaks the contract, such as a pending reply from a command that may
  /// not wait. The default stops a debug build, since it is the applet's bug. Tests replace it.
  var reportContractViolation: (String) -> Void = { assertionFailure($0) }

  private let schedule: Scheduler
  private var queue: [Entry] = []
  private var head = 0
  private var drainScheduled = false
  private var pending: [Int: PendingEntry] = [:]
  private var nextPendingID = 0

  public init(
    maximumQueued: Int = 256, deliveriesPerTurn: Int = 32, maximumPending: Int = 64,
    schedule: @escaping Scheduler = ControlDispatcher.nextMainTurn
  ) {
    self.maximumQueued = maximumQueued
    self.deliveriesPerTurn = deliveriesPerTurn
    self.maximumPending = maximumPending
    self.schedule = schedule
  }

  isolated deinit {
    let closed = AppletCommandError(.notFound, "the window closed")

    for entry in queue[head...] { entry.reply(.failure(closed)) }
    for entry in pending.values { entry.answer(.failure(closed)) }
  }

  public static func nextMainTurn(_ body: @escaping @MainActor () -> Void) {
    DispatchQueue.main.async { MainActor.assumeIsolated(body) }
  }

  /// How many commands wait for delivery.
  public var queuedCount: Int { queue.count - head }

  /// How many pending replies wait for their applets.
  public var pendingCount: Int { pending.count }

  /// Checks a command and queues it for `applet`. A command that fails a check is answered at
  /// once and never queued.
  ///
  /// A command that names a path needs `reads` to hold an open for each path. Without one the
  /// command is refused, so a caller that holds no path-reading power can never make an applet read.
  public func submit(
    _ submission: AppletCommandSubmission, to applet: any Applet, authority: @escaping Authority,
    reads: CommandReads = .none, reply: @escaping Reply
  ) {
    switch check(submission, for: applet, authority: authority, reads: reads) {
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

      queue.append(
        Entry(
          applet: handler, command: command, opened: reads.opened, access: reads.access,
          authority: authority, reply: reply))
      scheduleDrain()
    }
  }

  /// The path-typed arguments a command would carry, by the argument's name, when the applet
  /// declares the command and the arguments fit. A caller asks before it opens anything. An empty
  /// answer means the command reads no path, or that it will fail a check before it could.
  public func pathArguments(of submission: AppletCommandSubmission, for applet: any Applet)
    -> [(name: String, path: String)]
  {
    guard let handler = applet as? any AppletCommandHandling,
      handler.commandSchema.appletType == submission.appletType,
      let declared = handler.commandSchema.command(named: submission.name),
      case .object(let fields) = submission.arguments,
      (try? declared.arguments.validate(fields, at: "")) != nil
    else { return [] }

    var found: [(name: String, path: String)] = []

    declared.arguments.collectPaths(in: fields, at: "", into: &found)

    return found
  }

  private func check(
    _ submission: AppletCommandSubmission, for applet: any Applet, authority: Authority,
    reads: CommandReads
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

    guard schema.version.accepts(submission.schemaVersion) else {
      let reason =
        submission.schemaVersion.major == schema.version.major
        ? "a later minor than the applet has"
        : "another major than the applet has"

      return .failure(
        AppletCommandError(
          .unsupportedVersion,
          "the \(schema.appletType) applet takes command schema version \(schema.version.major) "
            + "with a minor up to \(schema.version.minor), and the command was written for "
            + "\(submission.schemaVersion), \(reason). Update the program that sent it, or "
            + "uniterm."))
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

    var paths: [(name: String, path: String)] = []

    declared.arguments.collectPaths(in: fields, at: "", into: &paths)

    for path in paths {
      switch reads.opened[path.name] {
      case nil:
        return .failure(Self.unreadable)

      case .failure(let error)?:
        return .failure(Self.refusal(for: error))

      case .success?:
        continue
      }
    }

    return .success(
      (
        handler,
        ValidatedAppletCommand(
          name: submission.name, arguments: declared.arguments.strippingPaths(from: fields))
      ))
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

    let access = entry.access()
    var opened: [String: OpenedPath] = [:]

    for (name, result) in entry.opened {
      switch result {
      case .failure(let error):
        entry.reply(.failure(Self.refusal(for: error)))
        return

      case .success(let path):
        guard path.isWithin(access.scope) else {
          entry.reply(.failure(Self.unreadable))
          return
        }

        opened[name] = path
      }
    }

    let command = ValidatedAppletCommand(
      name: entry.command.name, arguments: entry.command.arguments, opened: opened,
      access: access)
    let outcome: AppletCommandReply

    do {
      outcome = try applet.perform(command)
    } catch {
      entry.reply(.failure(error))
      return
    }

    switch outcome {
    case .immediate(let value):
      entry.reply(.success(value))

    case .pending(let reply):
      guard applet.commandSchema.command(named: entry.command.name)?.mayWait == true else {
        let name = entry.command.name
        let refusal = AppletCommandError(
          .failed, "the \(name) command is not one that may wait for a reply")

        reportContractViolation("the \(name) command answered pending but may not wait")
        reply.cancel(refusal)
        entry.reply(.failure(refusal))
        return
      }

      hold(reply, for: entry, applet: applet)
    }
  }

  // MARK: Reads

  /// The one answer for a path the caller may not read, whatever the reason. It never says whether
  /// the path exists, what it is, or whether the scope held it.
  static let unreadable = AppletCommandError(.refused, "uniterm cannot read that path for you")

  private static func refusal(for error: ScopedOpenError) -> AppletCommandError {
    switch error {
    case .unavailable: return unreadable
    case .missing: return AppletCommandError(.failed, "nothing is at that path")
    case .unsupported:
      return AppletCommandError(.failed, "that path is neither a file nor a folder")
    case .denied: return AppletCommandError(.failed, "the system did not allow reading that path")
    case .tooManyLinks: return AppletCommandError(.failed, "that path goes through too many links")
    case .notGranted:
      return AppletCommandError(
        .refused,
        "this run may not read paths now. It declared the power, and the user allowed the run "
          + "once. Allow for This Run or trust it, and run it again, to let it read")
    }
  }

  // MARK: Pending replies

  private func hold(
    _ reply: PendingReply, for entry: Entry, applet: any AppletCommandHandling
  ) {
    guard pending.count < maximumPending else {
      let busy = AppletCommandError(
        .busy, "\(maximumPending) commands already wait for a reply in this window. Try again.")

      reply.cancel(busy)
      entry.reply(.failure(busy))
      return
    }

    let id = nextPendingID

    nextPendingID += 1

    pending[id] = PendingEntry(
      applet: applet, reply: reply, authority: entry.authority, answer: entry.reply)

    reply.attach { [weak self] result in self?.finish(id, with: result) }
  }

  /// Answers a pending reply once. A success reaches the caller only if its authority still holds.
  private func finish(_ id: Int, with result: Result<JSONValue, AppletCommandError>) {
    guard let entry = pending.removeValue(forKey: id) else { return }

    switch result {
    case .failure(let error):
      entry.answer(.failure(error))

    case .success(let value):
      if let refusal = entry.authority() {
        entry.answer(.failure(refusal))
      } else {
        entry.answer(.success(value))
      }
    }
  }

  /// Asks every pending reply's authority again, and fails each one that is refused now or whose
  /// applet is gone. The window calls it whenever a caller's authority may have ended: a
  /// revocation, a run's end, a disconnect, or a pane's close.
  public func revalidatePending() {
    for id in pending.keys.sorted() {
      guard let entry = pending[id] else { continue }

      if entry.applet == nil {
        entry.reply.cancel(AppletCommandError(.notFound, "the pane closed"))
      } else if let refusal = entry.authority() {
        entry.reply.cancel(refusal)
      }
    }
  }

  /// Fails every pending reply with `error`, as when the window closes.
  public func failAllPending(_ error: AppletCommandError) {
    for id in pending.keys.sorted() {
      pending[id]?.reply.cancel(error)
    }
  }
}
