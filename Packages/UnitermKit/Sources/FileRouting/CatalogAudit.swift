import AppletKit
import Foundation

/// A fault in the set of applet declarations. A test fails on any of these.
public enum CatalogProblem: Sendable, Equatable {
  /// Two applets claim the same type at the same rank, so only a tiebreak could pick one.
  case sameRankClaim(type: String, rank: OpenRank, applets: [String])

  /// A declared type the system lacks and the host does not import.
  case unknownType(type: String, applet: String)

  /// An imported type that names no type it conforms to. A file of that type resolves to a
  /// dynamic type, which matches no declaration.
  case importedWithoutConformance(type: String, applet: String)

  /// An applet declares `public.directory`. It must declare `public.folder`, so a package is not
  /// taken for a folder.
  case declaresDirectory(applet: String)
}

public enum CatalogAudit {
  /// Checks a set of declarations. `imported` is the host's own imported types, each with the types
  /// it conforms to. A declared type is fine when the system declares it, or when it is imported
  /// with at least one conformance.
  public static func problems(
    in declarations: [AppletTypeDeclaration], types: any ContentTypeSystem,
    imported: [String: Set<String>] = [:]
  ) -> [CatalogProblem] {
    var problems: [CatalogProblem] = []
    var claimants: [String: [String]] = [:]

    for declaration in declarations {
      for opened in declaration.opens {
        let key = "\(opened.identifier)\u{0}\(opened.rank.rawValue)"
        claimants[key, default: []].append(declaration.typeID)

        if opened.identifier == "public.directory" {
          problems.append(.declaresDirectory(applet: declaration.typeID))
        }

        if types.isKnown(opened.identifier) { continue }

        if let conformances = imported[opened.identifier] {
          if conformances.isEmpty {
            problems.append(
              .importedWithoutConformance(type: opened.identifier, applet: declaration.typeID))
          }
        } else {
          problems.append(.unknownType(type: opened.identifier, applet: declaration.typeID))
        }
      }
    }

    for declaration in declarations {
      for opened in declaration.opens {
        let key = "\(opened.identifier)\u{0}\(opened.rank.rawValue)"

        guard let applets = claimants[key], Set(applets).count > 1,
          applets.first == declaration.typeID
        else { continue }

        problems.append(
          .sameRankClaim(type: opened.identifier, rank: opened.rank, applets: applets.sorted()))
      }
    }

    return problems
  }
}
