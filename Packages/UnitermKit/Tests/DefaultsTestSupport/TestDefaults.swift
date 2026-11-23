import Foundation

/// A defaults domain of its own for one test.
///
/// `removePersistentDomain(forName:)` empties a domain but leaves its 42-byte plist in
/// `~/Library/Preferences`. A test run then adds one file per suite. `discard()` also deletes
/// that file.
public final class TestDefaults: @unchecked Sendable {
  public let suite: String
  public let defaults: UserDefaults

  public init(prefix: String = "uniterm.tests") {
    suite = "\(prefix).\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suite)!
  }

  /// The plist `cfprefsd` keeps for the suite. It exists only after the first write.
  public var plistURL: URL {
    URL(fileURLWithPath: NSHomeDirectory())
      .appendingPathComponent("Library/Preferences/\(suite).plist")
  }

  /// A second handle on the same suite, as another store in the same process would open it.
  public func reopen() -> UserDefaults {
    UserDefaults(suiteName: suite)!
  }

  /// Removes the suite and its preference file.
  ///
  /// `removePersistentDomain(forName:)` makes `cfprefsd` write an emptied file about 20 seconds
  /// later. That write lands after any unlink made here, so the file stays. `defaults delete` goes
  /// through `cfprefsd` and leaves nothing pending. It runs first. The unlink catches a file the
  /// suite wrote before the delete.
  public func discard() {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
    process.arguments = ["delete", suite]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice

    try? process.run()
    process.waitUntilExit()

    defaults.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: plistURL)
  }
}
