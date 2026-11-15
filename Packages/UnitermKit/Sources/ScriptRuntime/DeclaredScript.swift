import CJanet
import Foundation

/// What a script file's first form says, as Janet's own parser reads it. The reader evaluates
/// nothing.
enum DeclaredScript {
  enum Reading: Equatable {
    /// The first form is not a declaration.
    case undeclared

    /// The first form is a valid declaration, converted to the JSON the app reads.
    case declared(json: String)

    /// The file has a declaration problem. The text names it.
    case invalid(String)
  }

  /// Reads `source` in a VM of its own on the calling thread. No other VM may be running there.
  static func read(_ source: Data) -> Reading {
    var declaration = uniterm_declaration()

    defer { uniterm_janet_free_declaration(&declaration) }

    let status = source.withUnsafeBytes { raw in
      uniterm_janet_read_declaration(
        raw.bindMemory(to: UInt8.self).baseAddress, raw.count, &declaration)
    }

    switch status {
    case UNITERM_DECLARATION_FOUND:
      guard let json = declaration.json else { return .invalid("the declaration was empty") }

      return .declared(
        json: String(
          decoding: UnsafeBufferPointer(
            start: UnsafeRawPointer(json).assumingMemoryBound(to: UInt8.self),
            count: declaration.json_length), as: UTF8.self))

    case UNITERM_DECLARATION_INVALID:
      return .invalid(
        withUnsafeBytes(of: declaration.message) {
          String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
        })

    default:
      return .undeclared
    }
  }
}
