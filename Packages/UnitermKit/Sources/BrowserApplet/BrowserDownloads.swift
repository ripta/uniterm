import AppletKit
import BrowserModel
import Foundation
import OSLog
import WebKit

/// What the manager tells the applet.
@MainActor
protocol BrowserDownloadsDelegate: AnyObject {
  /// The list of downloads, or one's progress, changed.
  func downloadsDidChange(_ downloads: BrowserDownloads)

  func downloads(_ downloads: BrowserDownloads, finished name: String, at url: URL)

  func downloads(_ downloads: BrowserDownloads, failed name: String, reason: String)
}

/// Every download of one pane.
///
/// The pane holds the `WKDownload`, not the tab. A tab closes, and a web view goes with it, but a
/// download is the user's file and has its own life: navigating the tab away does not end it.
/// Closing a tab or the pane cancels the downloads they own, after the applet has asked.
///
/// A download writes under a temporary name in the folder `directory` names. It takes its final
/// name when it finishes. A failed or cancelled download removes the temporary file.
///
/// The Downloads folder can sit on a network or iCloud volume, so every file operation runs off the
/// main thread, through `DownloadFileOperations`, and its outcome comes back as a later event. A
/// download that is finishing still counts as running, and a cancel that arrives meanwhile
/// resolves once: nothing is announced, and the file the finish makes is removed.
@MainActor
final class BrowserDownloads: NSObject, WKDownloadDelegate {
  /// One download in flight.
  @MainActor
  final class Entry {
    let download: WKDownload
    weak var tab: BrowserTab?

    /// The page the download came from, and the address it fetched, for the quarantine record.
    let origin: URL?
    let source: URL?

    var name: String
    var temporary: URL?
    var directory: URL?
    var isCancelled = false

    /// WebKit has finished the download and its file is being named and marked off the main thread.
    var isFinalizing = false

    /// Why the browser itself ended the download, when WebKit would report it as a cancel.
    var failure: String?

    var observation: NSKeyValueObservation?
    var percent = -1

    /// Ends a deferred cancel that no byte ever releases.
    var graceTimer: Task<Void, Never>?

    /// Whether any byte of the body has reached WebKit.
    var hasData: Bool { download.progress.completedUnitCount > 0 }

    init(download: WKDownload, tab: BrowserTab, origin: URL?) {
      self.download = download
      self.tab = tab
      self.origin = origin
      self.source = download.originalRequest?.url
      self.name = DownloadName.fallback
    }

    var fraction: Double? {
      download.progress.isIndeterminate ? nil : download.progress.fractionCompleted
    }
  }

  weak var delegate: (any BrowserDownloadsDelegate)?

  /// The folder downloads land in, asked at each download so a changed folder takes effect.
  private let directory: @MainActor () -> URL?

  private let files: DownloadFileOperations
  private let sweeper: DownloadSweeper
  private let clock: @Sendable () -> Date

  private var entries: [ObjectIdentifier: Entry] = [:]
  private var order: [ObjectIdentifier] = []

  /// Cancelled downloads, held until WebKit says it has let go. WebKit may create the partial file
  /// after the cancel, so the file is removed again when it lets go.
  private var cancelling: [ObjectIdentifier: (download: WKDownload, temporary: URL?)] = [:]

  /// Cancelled downloads that WebKit has not been told to cancel, because no byte has arrived yet.
  /// WebKit's network process treats a cancel that beats the first byte as an invalid message and
  /// restarts, which drops every other pane's session state and loads. So the cancel waits for the
  /// first byte, or for `cancelGrace`, and the entry is out of the list meanwhile. Measured: a cancel
  /// before data lost a session cookie in another tab, and a cancel after data did not.
  private var deferred: [ObjectIdentifier: Entry] = [:]

  /// How long a cancel waits for a first byte that never comes, before it goes to WebKit anyway.
  private let cancelGrace: Duration

  private let log = Logger(subsystem: "dev.uniterm.app", category: "browser-downloads")

  /// The newest finished file, for Reveal Latest Download.
  private(set) var latest: (url: URL, name: String)?

  init(
    directory: @escaping @MainActor () -> URL?, files: DownloadFileOperations,
    sweeper: DownloadSweeper, clock: @escaping @Sendable () -> Date,
    cancelGrace: Duration = .seconds(30)
  ) {
    self.directory = directory
    self.files = files
    self.sweeper = sweeper
    self.clock = clock
    self.cancelGrace = cancelGrace
  }

  /// How many cancelled downloads wait for a first byte.
  var deferredCancelCount: Int { deferred.count }

  var active: [Entry] { order.compactMap { entries[$0] } }

  var isRunning: Bool { !entries.isEmpty }

  /// The file names of the downloads in flight, oldest first.
  var runningNames: [String] { active.map(\.name) }

  func running(for tab: BrowserTab) -> [Entry] { active.filter { $0.tab === tab } }

  /// Takes a download WebKit made from a navigation in `tab`.
  func adopt(_ download: WKDownload, from tab: BrowserTab) {
    let entry = Entry(download: download, tab: tab, origin: tab.committedURL)
    let id = ObjectIdentifier(download)

    entries[id] = entry
    order.append(id)

    download.delegate = self

    entry.observation = download.progress.observe(\.completedUnitCount) {
      [weak self, weak entry] _, _ in
      Task { @MainActor in
        guard let self, let entry else { return }

        self.progressChanged(entry)
      }
    }

    delegate?.downloadsDidChange(self)
  }

  /// Cancels the downloads `tab` started. They leave no file and post nothing.
  func cancel(for tab: BrowserTab) {
    for entry in running(for: tab) { cancel(entry) }
  }

  func cancelAll() {
    for entry in active { cancel(entry) }
  }

  private func cancel(_ entry: Entry) {
    let id = ObjectIdentifier(entry.download)

    guard entries[id] != nil else { return }

    entry.isCancelled = true
    remove(id)

    delegate?.downloadsDidChange(self)

    // A finishing download is already done, and its file belongs to the finish, which removes it.
    if entry.isFinalizing {
      entry.observation = nil
      return
    }

    guard entry.hasData else {
      deferred[id] = entry
      entry.graceTimer = Task { @MainActor [self] in
        try? await Task.sleep(for: cancelGrace)

        guard !Task.isCancelled else { return }

        performCancel(entry)
      }
      return
    }

    performCancel(entry)
  }

  /// Tells WebKit to cancel. A late write may bring the partial file back, so it is removed again
  /// when WebKit lets go.
  private func performCancel(_ entry: Entry) {
    let id = ObjectIdentifier(entry.download)

    guard deferred.removeValue(forKey: id) != nil || entries[id] != nil else { return }

    entry.graceTimer?.cancel()
    entry.graceTimer = nil
    entry.observation = nil

    cancelling[id] = (entry.download, entry.temporary)

    entry.download.cancel { [weak self] _ in
      self?.letGo(id)
    }
  }

  /// A deferred download ended before its cancel went out: it finished, or it failed. Nothing is left
  /// to cancel, and its file is removed.
  private func endDeferred(_ id: ObjectIdentifier) -> Bool {
    guard let entry = deferred.removeValue(forKey: id) else { return false }

    entry.graceTimer?.cancel()
    entry.graceTimer = nil
    entry.observation = nil

    if let temporary = entry.temporary { discard(temporary) }

    return true
  }

  /// WebKit is done with a cancelled download, so no later write can bring its file back.
  private func letGo(_ id: ObjectIdentifier) {
    guard let held = cancelling.removeValue(forKey: id) else { return }

    if let temporary = held.temporary { discard(temporary) }
  }

  /// Removes a file off the main thread.
  private func discard(_ url: URL) {
    let files = files

    Task.detached(priority: .utility) { files.discard(url) }
  }

  private func remove(_ id: ObjectIdentifier) {
    entries.removeValue(forKey: id)
    order.removeAll { $0 == id }
  }

  private func progressChanged(_ entry: Entry) {
    let id = ObjectIdentifier(entry.download)

    if deferred[id] != nil {
      if entry.hasData { performCancel(entry) }

      return
    }

    guard entries[id] != nil else { return }

    let percent = entry.fraction.map { Int(($0 * 100).rounded(.down)) } ?? -1

    guard percent != entry.percent else { return }

    entry.percent = percent
    delegate?.downloadsDidChange(self)
  }

  // MARK: WKDownloadDelegate

  func download(
    _ download: WKDownload, decideDestinationUsing response: URLResponse,
    suggestedFilename: String, completionHandler: @escaping @MainActor @Sendable (URL?) -> Void
  ) {
    let known = ObjectIdentifier(download)

    guard let entry = entries[known] ?? deferred[known] else {
      completionHandler(nil)
      return
    }

    entry.name = DownloadName.sanitize(suggestedFilename)

    guard let folder = directory() else {
      entry.failure = "There is no Downloads folder."
      completionHandler(nil)
      return
    }

    let files = files
    let now = clock()

    if sweeper.shouldSweep(folder) {
      Task.detached(priority: .utility) { files.sweep(folder, now) }
    }

    Task { @MainActor [weak self, weak entry] in
      let problem = await Task.detached(priority: .utility) { () -> String? in
        do {
          try files.prepareFolder(folder)
          return nil
        } catch {
          return error.localizedDescription
        }
      }.value

      let id = ObjectIdentifier(download)

      // A cancel that beat this answer still gets a destination, since refusing one would cancel
      // the download in WebKit before its first byte. The deferred cancel then ends it.
      guard let self, let entry, entries[id] != nil || deferred[id] != nil else {
        completionHandler(nil)
        return
      }

      if let problem {
        entry.failure = "The Downloads folder is not available. \(problem)"
        completionHandler(nil)
        return
      }

      let temporary = DownloadFiles.temporaryURL(in: folder)

      entry.temporary = temporary
      entry.directory = folder

      delegate?.downloadsDidChange(self)
      completionHandler(temporary)
    }
  }

  func download(
    _ download: WKDownload, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    decisionHandler: @escaping @MainActor @Sendable (WKDownload.RedirectPolicy) -> Void
  ) {
    let scheme = request.url?.scheme?.lowercased()

    decisionHandler(scheme == "http" || scheme == "https" ? .allow : .cancel)
  }

  func downloadDidFinish(_ download: WKDownload) {
    let id = ObjectIdentifier(download)

    if endDeferred(id) { return }

    guard let entry = entries[id], !entry.isFinalizing else { return }

    entry.observation = nil

    guard let temporary = entry.temporary, let folder = entry.directory else {
      remove(id)
      finish(entry, failing: "The download had no file to keep.")
      return
    }

    entry.isFinalizing = true
    delegate?.downloadsDidChange(self)

    let files = files
    let name = entry.name
    let origin = entry.origin
    let source = entry.source

    Task { @MainActor [weak self] in
      let result = await Task.detached(priority: .utility) {
        Result { try files.finish(temporary, name, folder, origin, source) }
      }.value

      self?.finalized(entry, temporary: temporary, result)
    }
  }

  /// The file is named and marked, or that failed. A cancel that came meanwhile took the entry out
  /// of the list already, so the outcome is silent and the file is removed.
  private func finalized(_ entry: Entry, temporary: URL, _ result: Result<URL, any Error>) {
    let id = ObjectIdentifier(entry.download)

    if entries[id] === entry { remove(id) }

    switch result {
    case .success(let url):
      guard !entry.isCancelled else {
        discard(url)
        return
      }

      latest = (url, url.lastPathComponent)

      delegate?.downloadsDidChange(self)
      delegate?.downloads(self, finished: url.lastPathComponent, at: url)

    case .failure(let error):
      discard(temporary)
      log.error("a finished download could not be kept: \(String(describing: error))")

      guard !entry.isCancelled else { return }

      finish(entry, failing: error.localizedDescription)
    }
  }

  func download(
    _ download: WKDownload, didFailWithError error: any Error, resumeData: Data?
  ) {
    let id = ObjectIdentifier(download)

    letGo(id)

    if endDeferred(id) { return }

    guard let entry = entries[id] else { return }

    remove(id)
    entry.observation = nil

    if let temporary = entry.temporary { discard(temporary) }

    finish(entry, failing: entry.failure ?? error.localizedDescription)
  }

  private func finish(_ entry: Entry, failing reason: String) {
    delegate?.downloadsDidChange(self)
    delegate?.downloads(self, failed: entry.name, reason: reason)
  }
}
