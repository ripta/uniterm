import AppKit
import FileRouting
import Foundation
import OSLog
import StatusKit

/// Takes the files that Launch Services hands the app, decides whether the sender may open them,
/// and routes them to panes.
///
/// A refused open touches nothing. No path is statted, opened, or typed before the sender is
/// authorized, so a refused program learns nothing about the files it names and cannot raise a
/// privacy prompt under uniterm's name.
///
/// An open that arrives before layout restore finishes waits. `launchFinished` replays it after
/// every launch outcome. The layout's default window decision asks `hasPending` first, so a
/// cold-launch open does not start a shell beside the routed pane.
@MainActor
public final class LaunchOpenCoordinator {
  private static let logger = Logger(subsystem: "dev.uniterm.app", category: "open")

  private struct Request {
    let files: [URL]
  }

  private let windows: WindowSet
  private let opener: RoutedOpener
  private let now: @MainActor () -> TimeInterval
  private let openFallbackWindow: @MainActor () -> Void

  private var coalescer: RefusalCoalescer
  private var queue: [Request] = []
  private var ready = false
  private var draining = false
  private var windowCheckDue = false

  /// `openFallbackWindow` runs after the replay when no window is open, so a launch whose only
  /// opens were refused or failed still shows a window.
  public init(
    windows: WindowSet, opener: RoutedOpener,
    coalescer: RefusalCoalescer = RefusalCoalescer(),
    now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    openFallbackWindow: @escaping @MainActor () -> Void
  ) {
    self.windows = windows
    self.opener = opener
    self.coalescer = coalescer
    self.now = now
    self.openFallbackWindow = openFallbackWindow
  }

  /// True while an authorized open waits for layout restore. Refused opens never wait.
  public var hasPending: Bool { !queue.isEmpty }

  /// Handles one open-documents event. The reply to the sender never depends on the outcome, so
  /// this returns nothing.
  public func receive(_ urls: [URL], from sender: SenderIdentity?) {
    switch OpenAuthority.decide(for: sender) {
    case .refused(let name):
      refuse(sender: name)

    case .userAct:
      queue.append(Request(files: urls))
      drainIfReady()
    }
  }

  /// Layout restore is over. Replays every open that waited, then opens a window if there is none.
  public func launchFinished() {
    ready = true
    windowCheckDue = true
    drainIfReady()

    if !draining {
      ensureWindow()
    }
  }

  private func refuse(sender: String) {
    Self.logger.info("refused an open from \(sender, privacy: .public)")

    guard let text = coalescer.note(sender: sender, at: now()) else { return }

    windows.post(level: .warning, text: text)
  }

  private func drainIfReady() {
    guard ready, !draining, !queue.isEmpty else { return }

    draining = true

    Task { @MainActor [weak self] in
      guard let self else { return }

      while !self.queue.isEmpty {
        await self.run(self.queue.removeFirst())
      }

      self.draining = false
      self.ensureWindow()
    }
  }

  private func ensureWindow() {
    guard windowCheckDue else { return }

    windowCheckDue = false

    guard windows.controllers.isEmpty else { return }

    openFallbackWindow()
  }

  private func run(_ request: Request) async {
    let files = request.files.filter(\.isFileURL)

    if files.count < request.files.count {
      windows.post(
        level: .warning,
        text:
          "\(request.files.count - files.count) item(s) were not local files, "
          + "so they were not opened."
      )
    }

    guard !files.isEmpty else { return }

    let anchor = windows.launchAnchor()

    if let anchor {
      windows.bringForward(anchor.controller)
    } else {
      NSApp.activate()
    }

    await opener.open(files, from: anchor)
  }
}
