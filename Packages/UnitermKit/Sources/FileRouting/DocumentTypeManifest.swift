import AppletKit
import Foundation

/// What the host's `Info.plist` tells Launch Services about the types uniterm opens, checked
/// against the applet declarations.
public enum DocumentTypeManifest {
  /// A way the plist disagrees with the declarations. A test fails on any of these.
  public enum Problem: Sendable, Equatable {
    /// An applet declares a type that no document type entry lists.
    case undeclared(type: String)

    /// A document type entry lists a type that no applet declares.
    case unclaimed(type: String)

    /// An entry whose rank is not Alternate. Anything stronger would displace another app.
    case rankNotAlternate(entry: String, rank: String?)
  }

  static let rankKey = "LSHandlerRank"
  static let typesKey = "LSItemContentTypes"
  static let alternate = "Alternate"

  /// The document type entries of a plist.
  public static func documentTypes(in plist: [String: Any]) -> [[String: Any]] {
    plist["CFBundleDocumentTypes"] as? [[String: Any]] ?? []
  }

  /// The types the plist imports, each with the types it conforms to. The host's imports feed the
  /// catalog audit.
  public static func importedTypes(in plist: [String: Any]) -> [String: Set<String>] {
    let entries = plist["UTImportedTypeDeclarations"] as? [[String: Any]] ?? []
    var table: [String: Set<String>] = [:]

    for entry in entries {
      guard let identifier = entry["UTTypeIdentifier"] as? String else { continue }

      table[identifier] = Set(entry["UTTypeConformsTo"] as? [String] ?? [])
    }

    return table
  }

  /// Every disagreement between the plist's document types and the declarations. The set of types
  /// must match exactly, and every rank must be Alternate, whatever rank an applet declares.
  public static func problems(in plist: [String: Any], declarations: [AppletTypeDeclaration])
    -> [Problem]
  {
    var problems: [Problem] = []
    var listed: Set<String> = []

    for entry in documentTypes(in: plist) {
      let name = entry["CFBundleTypeName"] as? String ?? "(unnamed)"
      let rank = entry[rankKey] as? String

      if rank != alternate {
        problems.append(.rankNotAlternate(entry: name, rank: rank))
      }

      listed.formUnion(entry[typesKey] as? [String] ?? [])
    }

    let declared = Set(declarations.flatMap { $0.opens.map(\.identifier) })

    problems += declared.subtracting(listed).sorted().map { .undeclared(type: $0) }
    problems += listed.subtracting(declared).sorted().map { .unclaimed(type: $0) }

    return problems
  }
}
