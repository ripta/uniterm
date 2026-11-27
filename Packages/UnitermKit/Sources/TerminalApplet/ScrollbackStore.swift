import Foundation

/// Keeps terminal tabs' scrollback from a quit to the next launch.
///
/// Each tab's text is one file, named by an ID that the tab's description holds. A restore reads
/// the file and deletes it, so the text is on disk only between a quit and the launch after it.
/// The folder and the files are private to the user.
public struct ScrollbackStore: Sendable {
  public let directory: URL

  /// A file this old was left by a quit whose layout never came back, such as one set aside.
  static let staleAge: TimeInterval = 30 * 24 * 60 * 60

  public init(directory: URL) {
    self.directory = directory
  }

  /// Writes one tab's text and returns its ID. It also deletes stale files.
  public func write(_ text: String) throws -> String {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

    removeStaleFiles()

    let id = UUID().uuidString
    let file = url(for: id)
    try Data(text.utf8).write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    return id
  }

  /// Reads the text with this ID and deletes its file. Nil when the ID is not one this store makes,
  /// or the file is gone. An ID comes from a layout file, so it never names a path.
  public func take(_ id: String) -> String? {
    guard UUID(uuidString: id)?.uuidString == id else { return nil }

    let file = url(for: id)
    defer { try? FileManager.default.removeItem(at: file) }

    guard let data = try? Data(contentsOf: file) else { return nil }

    return String(decoding: data, as: UTF8.self)
  }

  /// Deletes the file with this ID, if there is one.
  public func remove(_ id: String) {
    guard UUID(uuidString: id)?.uuidString == id else { return }

    try? FileManager.default.removeItem(at: url(for: id))
  }

  func removeStaleFiles(now: Date = Date()) {
    let manager = FileManager.default
    let names = (try? manager.contentsOfDirectory(atPath: directory.path)) ?? []

    for name in names where name.hasSuffix(".txt") {
      let file = directory.appending(path: name)
      let modified = (try? manager.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date

      if let modified, now.timeIntervalSince(modified) > Self.staleAge {
        try? manager.removeItem(at: file)
      }
    }
  }

  private func url(for id: String) -> URL {
    directory.appending(path: "\(id).txt")
  }
}
