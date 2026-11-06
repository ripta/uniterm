import Foundation
import LayoutKit
import OSLog
import StatusKit

/// Restores the saved layout at launch and keeps it saved while the app runs.
///
/// It owns the layout store for one app. At launch it takes the single-writer lock, reads the file,
/// and opens the saved windows, or one default window when there is nothing to restore. It then
/// saves after every layout change once the changes stop for a moment, and at once on quit.
///
/// Saving stays off while the launch runs, so a half-restored layout never replaces the file. It
/// stays off for the whole run when this instance could not take the lock, or when the file could
/// not be set aside. The file is then left exactly as it was.
@MainActor
public final class LayoutPersistence {
  /// What the launch did, for tests and the log.
  public enum Outcome: Equatable {
    /// The saved windows were restored.
    case restored(windows: Int)

    /// There was nothing to restore, or the file was set aside. A default window opened.
    case fresh

    /// Another running instance owns the layout. A default window opened, and nothing is saved.
    case secondInstance

    /// The layout could not be read or kept safe. A default window opened, and nothing is saved.
    case unavailable
  }

  private static let logger = Logger(subsystem: "dev.uniterm.app", category: "layout")

  private let store: LayoutStore
  private let windows: WindowSet
  private let saver: LayoutSaver
  private let afterLaunch: @MainActor (@escaping @MainActor () -> Void) -> Void

  /// `directory` holds the layout file. The debounce is how long the layout must stay unchanged
  /// before it is written.
  public convenience init(directory: URL, windows: WindowSet, debounce: TimeInterval = 1) {
    self.init(store: LayoutStore(directory: directory), windows: windows, debounce: debounce)
  }

  init(
    store: LayoutStore, windows: WindowSet, debounce: TimeInterval = 1,
    scheduler: @escaping LayoutScheduler = LayoutSaver.defaultScheduler,
    afterLaunch: @escaping @MainActor (@escaping @MainActor () -> Void) -> Void = { action in
      DispatchQueue.main.async { MainActor.assumeIsolated { action() } }
    }
  ) {
    self.store = store
    self.windows = windows
    self.afterLaunch = afterLaunch

    saver = LayoutSaver(
      debounce: debounce, scheduler: scheduler,
      snapshot: { windows.savedLayout() },
      write: { [store] layout in try store.save(layout) },
      onFailure: { error in
        Self.logger.error("the layout was not saved: \(String(describing: error))")
        windows.post(
          level: .error, source: .uniterm, text: "The layout was not saved: \(error)")
      })
  }

  /// `~/Library/Application Support/uniterm`, where the layout file lives.
  public static func defaultDirectory() throws -> URL {
    try LayoutStore.defaultDirectory()
  }

  /// Opens the windows for this launch. Throws only when not even a default window opens. Such a
  /// launch is not a crash, so it clears the launch marker and does not count toward the bound.
  ///
  /// `hasPendingOpen` is asked each time the launch is about to open a default window. When it says
  /// yes, the launch opens none, because a routed open waits to make the window. Whoever holds that
  /// open must open a window if it ends with none. A restored window still opens as saved.
  @discardableResult
  public func launch(hasPendingOpen: () -> Bool = { false }) throws -> Outcome {
    let writer: Bool

    do {
      writer = try store.acquire()
    } catch {
      return try openDefault(
        .unavailable, level: .error, notice: "The layout could not be restored or saved: \(error)",
        hasPendingOpen: hasPendingOpen)
    }

    guard writer else {
      return try openDefault(
        .secondInstance, level: .info,
        notice: "Another uniterm is running, so this window's layout is not saved.",
        hasPendingOpen: hasPendingOpen)
    }

    let result: LaunchResult

    do {
      result = try store.beginLaunch()
    } catch {
      store.release()

      return try openDefault(
        .unavailable, level: .error, notice: "The layout could not be restored or saved: \(error)",
        hasPendingOpen: hasPendingOpen)
    }

    let outcome: Outcome

    do {
      switch result {
      case .restored(let layout):
        outcome = try restore(layout, hasPendingOpen: hasPendingOpen)

      case .fresh(let notice):
        outcome = try openDefault(
          .fresh, level: .warning, notice: notice, hasPendingOpen: hasPendingOpen)
      }
    } catch {
      store.finishLaunch()
      store.release()
      throw error
    }

    windows.onLayoutChange = { [weak self] in self?.saver.layoutDidChange() }
    saver.enable()

    afterLaunch { [store] in store.finishLaunch() }
    return outcome
  }

  /// Writes the layout now, stops further saves, and lets go of the lock. Quitting calls it, so a
  /// change made an instant before the quit is still on disk.
  public func saveForQuit() {
    saver.saveNow()
    saver.disable()
    windows.onLayoutChange = nil
    store.release()
  }

  // MARK: Restore

  private func restore(_ layout: SavedLayout, hasPendingOpen: () -> Bool) throws -> Outcome {
    var opened = 0
    var failures: [String] = []

    for saved in layout.windows {
      do {
        try windows.open(restoring: RestoredWindow(saved: saved))
        opened += 1
      } catch {
        Self.logger.error("a saved window did not open: \(String(describing: error))")
        failures.append("\(error)")
      }
    }

    if (layout.windows.isEmpty || opened == 0) && !hasPendingOpen() {
      try windows.open()
    }

    if !failures.isEmpty {
      let kept = (try? store.keepCopyAside())?.lastPathComponent

      let copy = kept.map { " A copy of the saved layout was kept as \($0)." } ?? ""
      windows.post(
        level: .error, source: .uniterm,
        text: "\(failures.count) saved window(s) did not reopen: \(failures[0]).\(copy)")
    }

    return .restored(windows: opened)
  }

  private func openDefault(
    _ outcome: Outcome, level: StatusLevel, notice: String?, hasPendingOpen: () -> Bool
  ) throws -> Outcome {
    if !hasPendingOpen() {
      try windows.open()
    }

    if let notice {
      windows.post(level: level, source: .uniterm, text: notice)
    }

    return outcome
  }
}
