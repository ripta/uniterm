import AppletKit
import Foundation
import ImageViewerModel
import SourceAccess

/// Runs `action` after `seconds` and returns a closure that cancels it. A test hands the pane a
/// scheduler it fires by hand, so no test sleeps for a timeout.
public typealias ImageWaitScheduler =
  @MainActor (
    _ seconds: Double, _ action: @escaping @MainActor () -> Void
  ) -> @MainActor () -> Void

/// The pane's remote results and the waits on them.
///
/// A command with an effect answers at once with a handle, and its result is kept under that
/// handle. The `wait` command has no effect, so it holds a pending reply until the handle ends or
/// the wait times out. Closing the pane fails every wait and frees every handle.
///
/// A remote caller receives no events, so `wait` is how it learns what is shown.
@MainActor
final class ImageViewerRemote {
  /// The longest a wait may hold, however long the caller asks.
  nonisolated static let maxWait = 30_000

  /// How long a wait holds when the caller names no time.
  nonisolated static let defaultWait = 10_000

  static let realScheduler: ImageWaitScheduler = { seconds, action in
    let task = Task { @MainActor in
      try? await Task.sleep(for: .seconds(seconds))

      guard !Task.isCancelled else { return }

      action()
    }

    return { task.cancel() }
  }

  private struct Waiter {
    let serial: Int
    let reply: PendingReply
    let cancelTimer: @MainActor () -> Void

    /// What the caller may see. It is the access the caller held when it began to wait. A run's
    /// power can grow while it waits and can never shrink short of ending the run, which fails
    /// the wait, so the held access is never wider than the caller's own.
    let access: ReadAccess
  }

  private(set) var table = ImageHandleTable()
  var scheduler: ImageWaitScheduler = ImageViewerRemote.realScheduler

  private var waiters: [Int: [Waiter]] = [:]
  private var nextSerial = 0

  var hasRoom: Bool { table.hasRoom }

  var waitCount: Int { waiters.values.reduce(0) { $0 + $1.count } }

  var running: [ImageHandleTable.Entry] { table.running }

  /// Makes a handle. The caller checked `hasRoom` before it changed anything. A newer command
  /// replaces the running ones of its group, so the table never fills with handles that cannot end.
  func begin(_ kind: ImageHandleTable.Kind, wanted: String? = nil) -> Int? {
    supersede(navigation: kind.isNavigation)

    return table.open(kind, wanted: wanted)
  }

  /// Ends a handle and answers every wait on it.
  func settle(_ id: Int, _ outcome: ImageRemoteOutcome) {
    guard table.settle(id, outcome), let entry = table.entry(id) else { return }

    for waiter in waiters.removeValue(forKey: id) ?? [] {
      waiter.cancelTimer()
      waiter.reply.complete(Self.reply(for: entry, access: waiter.access))
    }
  }

  /// Ends the running handles of one group as superseded.
  func supersede(navigation: Bool) {
    for entry in table.running where entry.kind.isNavigation == navigation {
      settle(entry.id, .superseded)
    }
  }

  /// Ends every running handle but `kept` as superseded. A command that starts a load opens its own
  /// handle first, so an error from the open leaves nothing started, and keeps that handle.
  func supersedeAll(except kept: Int? = nil) {
    for entry in table.running where entry.id != kept {
      settle(entry.id, .superseded)
    }
  }

  /// Answers a wait. The reply is ready now when the handle ended, and pends when it did not.
  func wait(
    for id: Int, milliseconds: Int, access: ReadAccess
  ) throws(AppletCommandError) -> AppletCommandReply {
    guard let entry = table.entry(id) else {
      throw AppletCommandError(.notFound, "there is no result under that handle")
    }

    guard !entry.isSettled else {
      return .immediate(Self.reply(for: entry, access: access))
    }

    guard milliseconds > 0 else { return .immediate(ImageHandleTable.pendingReply) }

    let reply = PendingReply()

    nextSerial += 1

    let serial = nextSerial

    let cancelTimer = scheduler(Double(milliseconds) / 1000) { [weak self, weak reply] in
      guard let self, let reply else { return }

      waiters[id]?.removeAll { $0.serial == serial }

      reply.complete(ImageHandleTable.pendingReply)
    }

    waiters[id, default: []].append(
      Waiter(serial: serial, reply: reply, cancelTimer: cancelTimer, access: access))

    reply.onCancel = { [weak self] in
      guard let self else { return }

      let mine = waiters[id]?.first { $0.serial == serial }

      mine?.cancelTimer()
      waiters[id]?.removeAll { $0.serial == serial }
    }

    return .pending(reply)
  }

  /// The pane closed. Waits fail, since nothing ran for them, and the handles go.
  func close() {
    let all = waiters.values.flatMap { $0 }

    waiters = [:]
    table = ImageHandleTable()

    for waiter in all {
      waiter.cancelTimer()
      waiter.reply.fail(AppletCommandError(.notFound, "the pane closed"))
    }
  }

  private static func reply(for entry: ImageHandleTable.Entry, access: ReadAccess) -> JSONValue {
    ImageHandleTable.reply(for: entry, mayShow: { access.mayShow(source: $0) })
  }
}
