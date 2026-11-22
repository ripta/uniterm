import Foundation

/// Why a spec is refused. It names the spec's field, such as `items[2].validate.pattern`, and
/// never a controller file's term.
public struct FormSpecError: Error, Equatable, CustomStringConvertible, Sendable {
  public let field: String
  public let reason: String

  public init(field: String, reason: String) {
    self.field = field
    self.reason = reason
  }

  public var description: String { "\(field): \(reason)" }
}
