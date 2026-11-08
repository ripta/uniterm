import AppKit
import BrowserModel
import OSLog
import Preferences

/// Opens another app for an address, and says which app that would be. The browser never calls
/// `NSWorkspace` itself, so a test supplies one that launches nothing.
@MainActor
public protocol URLOpening: AnyObject {
  /// The name of the app that would open `url`, or nil when no app handles its scheme.
  func applicationName(toOpen url: URL) -> String?

  /// Opens `url` in its app. False when the system could not.
  func open(_ url: URL) -> Bool
}

/// The system's own opener.
@MainActor
public final class WorkspaceURLOpener: URLOpening {
  public init() {}

  public func applicationName(toOpen url: URL) -> String? {
    guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return nil }

    let name = FileManager.default.displayName(atPath: app.path(percentEncoded: false))

    return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
  }

  public func open(_ url: URL) -> Bool {
    NSWorkspace.shared.open(url)
  }
}

/// Shows a file in Finder. The browser never calls `NSWorkspace` for it, so a test supplies one that
/// opens nothing.
@MainActor
public protocol FileRevealing: AnyObject {
  func reveal(_ url: URL)
}

/// The system's own Finder reveal.
@MainActor
public final class WorkspaceFileRevealer: FileRevealing {
  public init() {}

  public func reveal(_ url: URL) {
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }
}

/// What the host gives each browser pane when it builds one. Every construction site passes the
/// same ones, so a restored pane and a new one cannot differ.
///
/// The search engine is a closure, not a value, so the pane reads the current setting each time it
/// builds a search address and a change applies to the next search in every open pane. The pane
/// never reads UserDefaults, and it never sees the settings store.
@MainActor
public struct BrowserServices {
  public var searchEngine: @MainActor () -> SearchEngine

  /// The list of hosts that asked for HTTPS only, shared by every browser pane.
  public var hsts: HSTSStore

  public var opener: any URLOpening

  /// The folder downloads land in. A closure, so a change of folder applies to the next download.
  /// It has no default at construction, so a test cannot reach the user's Downloads folder by
  /// omission.
  public var downloadsDirectory: @MainActor () -> URL?

  /// Shows a finished download in Finder.
  public var reveal: any FileRevealing

  /// The file work of a download, run off the main thread.
  public var downloadFiles: DownloadFileOperations

  /// Which folders were swept for leftovers this launch.
  public var downloadSweeper: DownloadSweeper

  /// How long a cancel of a download that has received no byte waits for one before it goes to
  /// WebKit anyway. WebKit's network process restarts on a cancel that beats the first byte.
  public var downloadCancelGrace: Duration

  /// The time a click is judged against. A test supplies its own, so the bound never races.
  public var clock: @Sendable () -> Date

  /// How a tab decides that a reload or navigation got no answer from a hung content process.
  public var hang: HangPolicy

  public init(
    searchEngine: @escaping @MainActor () -> SearchEngine, hsts: HSTSStore,
    downloadsDirectory: @escaping @MainActor () -> URL?, reveal: any FileRevealing,
    opener: any URLOpening = WorkspaceURLOpener(),
    downloadFiles: DownloadFileOperations = .live,
    downloadSweeper: DownloadSweeper = DownloadSweeper(),
    downloadCancelGrace: Duration = .seconds(30),
    clock: @escaping @Sendable () -> Date = Date.init, hang: HangPolicy = .live
  ) {
    self.searchEngine = searchEngine
    self.hsts = hsts
    self.downloadsDirectory = downloadsDirectory
    self.reveal = reveal
    self.downloadFiles = downloadFiles
    self.downloadSweeper = downloadSweeper
    self.downloadCancelGrace = downloadCancelGrace
    self.opener = opener
    self.clock = clock
    self.hang = hang
  }
}

extension BrowserServices {
  /// The services a running app gives its panes. The HSTS list lives in the browser's folder
  /// under `directory`, or under Application Support when `directory` is nil. A folder that cannot
  /// be named leaves the list in memory, which only costs the hint it carries. The app never names
  /// the list's type, so it needs no more than this product.
  public static func live(
    searchEngine: @escaping @MainActor () -> SearchEngine, directory: URL? = nil
  ) -> BrowserServices {
    let store: HSTSStore

    do {
      store = HSTSStore(file: try HSTSStore.defaultFile(in: directory))
    } catch {
      Logger(subsystem: "dev.uniterm.app", category: "browser")
        .error("the HSTS list has no folder, so it stays in memory: \(String(describing: error))")

      store = HSTSStore()
    }

    return BrowserServices(
      searchEngine: searchEngine, hsts: store,
      downloadsDirectory: {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
      },
      reveal: WorkspaceFileRevealer())
  }
}
