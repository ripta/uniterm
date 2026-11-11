import Darwin
import Foundation

/// The environment and directory a driver starts with. Nothing comes from uniterm's own
/// environment or from another pane.
///
/// The base holds HOME, USER, and LOGNAME from the user database, TMPDIR from the session's own
/// temporary folder, and a fixed PATH. A declared variable is added over the base, and may
/// replace one of its values.
public struct ExecEnvironment: Sendable, Equatable {
  public static let path = "/usr/bin:/bin:/usr/sbin:/sbin"

  public let home: String
  public let user: String
  public let temporaryDirectory: String

  public init(home: String, user: String, temporaryDirectory: String) {
    self.home = home
    self.user = user
    self.temporaryDirectory = temporaryDirectory
  }

  /// The current user's, read from the user database and the session, never from the environment.
  /// Nil when the user database has no entry for this user.
  public static func current() -> ExecEnvironment? {
    guard let entry = getpwuid(getuid()), let home = entry.pointee.pw_dir,
      let name = entry.pointee.pw_name
    else { return nil }

    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
    let temporary =
      length > 0 && length <= buffer.count
      ? String(decoding: buffer.prefix(length - 1).map { UInt8(bitPattern: $0) }, as: UTF8.self)
      : "/tmp/"

    return ExecEnvironment(
      home: String(cString: home), user: String(cString: name), temporaryDirectory: temporary)
  }

  public var base: [String: String] {
    ["HOME": home, "USER": user, "LOGNAME": user, "TMPDIR": temporaryDirectory, "PATH": Self.path]
  }

  /// The base with the declared values over it.
  public func environment(adding declared: [String: String]) -> [String: String] {
    base.merging(declared) { _, declared in declared }
  }
}
