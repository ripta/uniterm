import Foundation
import os

/// The browser's HSTS list, shared by every browser pane and kept in one file.
///
/// A header seen in any pane covers the host in all of them. The file is rewritten whenever the
/// list changes. A file that cannot be read starts an empty list, and one that cannot be written
/// leaves the list in memory only. Both are logged, since the list only ever hides an offer, and a
/// lost entry is a missing hint rather than lost user data. A file from a newer build is the
/// exception. It is never overwritten, so the newer build keeps its data. Clear Website Data calls
/// `removeAll`.
@MainActor
public final class HSTSStore {
  private struct File: Codable {
    var version: Int
    var list: HSTSList
  }

  /// Just the version. A newer build may change the rest of the file, so the version is read first
  /// and alone.
  private struct Header: Decodable {
    var version: Int
  }

  private static let currentVersion = 1
  private static let logger = Logger(subsystem: "dev.uniterm.app", category: "hsts")

  private var list: HSTSList
  private let fileURL: URL?

  /// Set when the file holds a newer version of the format. The store keeps its list in memory and
  /// never writes, so the newer build's data survives this one, as ADR-06 asks of a description.
  private var holdsNewerFile = false
  private let now: @Sendable () -> Date

  /// A store with no file, which forgets everything when it goes away.
  public init(now: @escaping @Sendable () -> Date = { Date() }) {
    list = HSTSList()
    fileURL = nil
    self.now = now
  }

  /// A store backed by `file`. The folder is made when the first change is written.
  public init(file: URL, now: @escaping @Sendable () -> Date = { Date() }) {
    self.fileURL = file
    self.now = now

    let loaded = Self.load(file, now: now())

    list = loaded.list
    holdsNewerFile = loaded.isNewer
  }

  /// The file's name inside the browser's folder.
  public static let fileName = "hsts.json"

  /// The list's file in the browser's folder under Application Support, beside the layout. A debug
  /// build and its tests name another folder, so they never touch the developer's list.
  public static func defaultFile(in directory: URL? = nil) throws -> URL {
    let folder =
      try directory
      ?? FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
      )
      .appending(path: "uniterm", directoryHint: .isDirectory)
      .appending(path: "Browser", directoryHint: .isDirectory)

    return folder.appending(path: fileName, directoryHint: .notDirectory)
  }

  public func contains(host: String) -> Bool {
    list.contains(host: host, now: now())
  }

  public func record(host: String, header: String) {
    guard list.record(host: host, header: header, now: now()) else { return }

    persist()
  }

  /// Records the header of a main-frame response, when the response came over HTTPS. A header on
  /// plain HTTP is ignored, since anyone on the path could have added it. WebKit delivers a
  /// response only after its certificate validated.
  public func noteResponse(from url: URL, header: String?) {
    guard url.scheme?.lowercased() == "https", let header,
      let host = url.host(percentEncoded: false)
    else { return }

    record(host: host, header: header)
  }

  public func removeAll() {
    guard !list.entries.isEmpty else { return }

    list.removeAll()
    persist()
  }

  public var count: Int { list.entries.count }

  private static func load(_ file: URL, now: Date) -> (list: HSTSList, isNewer: Bool) {
    guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else {
      return (HSTSList(), false)
    }

    do {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601

      let data = try Data(contentsOf: file)
      let header = try decoder.decode(Header.self, from: data)

      guard header.version == currentVersion else {
        logger.error("the HSTS list has version \(header.version), so it stays untouched")
        return (HSTSList(), true)
      }

      let stored = try decoder.decode(File.self, from: data)

      var list = stored.list
      list.prune(now: now)
      return (list, false)
    } catch {
      logger.error("the HSTS list could not be read: \(String(describing: error))")
      return (HSTSList(), false)
    }
  }

  private func persist() {
    guard let fileURL, !holdsNewerFile else { return }

    do {
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.sortedKeys]

      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try encoder.encode(File(version: Self.currentVersion, list: list))
        .write(to: fileURL, options: .atomic)
    } catch {
      Self.logger.error("the HSTS list could not be written: \(String(describing: error))")
    }
  }
}
