import Darwin
import Foundation

/// How two path components are told equal, as the volume holding them tells them.
///
/// APFS keeps the spelling a name was created with and compares names without regard to Unicode
/// normalization. A volume formatted case-insensitive, the default, also compares without regard to
/// case. A scope and a path therefore compare through a key, never as raw strings, so a different
/// spelling of the same name can neither widen nor narrow a scope.
public struct PathComparison: Sendable, Equatable {
  public let isCaseSensitive: Bool

  public init(isCaseSensitive: Bool) {
    self.isCaseSensitive = isCaseSensitive
  }

  /// Names equal only when they match exactly after normalization. A policy comparison with no
  /// volume to ask uses it, since it can only narrow what a scope covers.
  public static let exact = PathComparison(isCaseSensitive: true)

  /// The comparison of the volume holding `path`. A volume that cannot be asked compares exactly.
  public static func ofVolume(at path: String) -> PathComparison {
    let answer = pathconf(path, _PC_CASE_SENSITIVE)

    return answer == 0 ? PathComparison(isCaseSensitive: false) : .exact
  }

  /// The comparison of the volume holding the open `descriptor`.
  public static func ofVolume(descriptor: Int32) -> PathComparison {
    let answer = fpathconf(descriptor, _PC_CASE_SENSITIVE)

    return answer == 0 ? PathComparison(isCaseSensitive: false) : .exact
  }

  /// What two equal names share: the name in canonical decomposition, folded on a case-insensitive
  /// volume.
  public func key(_ component: String) -> String {
    let normalized = component.decomposedStringWithCanonicalMapping

    return isCaseSensitive ? normalized : Self.folded(normalized)
  }

  /// A name under Unicode case folding, as APFS folds. Lower casing is not enough: the long s
  /// (U+017F) lower-cases to itself and folds to s, and the Kelvin sign (U+212A) folds to k. A
  /// spelling that only the fold equates with a protected place must still be that place.
  ///
  /// Each scalar goes to upper case and back to lower case, which maps these and the other
  /// one-to-many cases the way the fold does. It uses the standard library's own tables.
  public static func folded(_ name: String) -> String {
    var result = ""

    for scalar in name.decomposedStringWithCanonicalMapping.unicodeScalars {
      result += scalar.properties.uppercaseMapping.lowercased()
    }

    return result
  }

  /// Names equal under the fold, whatever the volume says. Protected places compare this way, since
  /// hiding a name that only another volume would equate with one is always safe.
  public static let alwaysFolding = PathComparison(isCaseSensitive: false)

  public func areEqual(_ lhs: String, _ rhs: String) -> Bool {
    key(lhs) == key(rhs)
  }

  /// True when `directory` is `path`, or one of the folders on the way to it.
  public func isInside(_ path: [String], _ directory: [String]) -> Bool {
    guard path.count >= directory.count else { return false }

    for (index, name) in directory.enumerated() where !areEqual(path[index], name) {
      return false
    }

    return true
  }

  /// The names of a plain absolute path, or nil when the path is not one. A plain path is
  /// absolute and has no empty, `.`, or `..` component, no trailing slash, and no control
  /// character.
  public static func plainComponents(of path: String) -> [String]? {
    guard path.hasPrefix("/"), path.utf8.count <= ReadScope.maxPathBytes else { return nil }

    if path == "/" { return [] }

    let parts = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)

    guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
      !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
    else { return nil }

    return parts.map(String.init)
  }
}
