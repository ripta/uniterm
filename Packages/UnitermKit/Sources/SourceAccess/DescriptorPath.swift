import Darwin
import Foundation

/// The one reader of an open descriptor's real path.
///
/// Two checks lean on it with different meanings. A scoped open asks whether the path lies inside
/// a scope. A terminal click asks whether it equals the string the pane showed. Both must decode
/// the system's answer the same way, so neither keeps its own copy.
public enum DescriptorPath {
  /// The real path of an open descriptor, as the system reports it. Nil when the system gives none.
  public static func read(_ descriptor: Int32) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)

    guard fcntl(descriptor, F_GETPATH, &buffer) == 0 else { return nil }

    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }

    return String(decoding: bytes, as: UTF8.self)
  }
}
