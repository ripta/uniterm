import AppletCatalog
import AppletKit
import FileRouting
import Foundation
import XCTest

final class InfoPlistDriftTests: XCTestCase {
  private func loadPlist() throws -> [String: Any] {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("App/Info.plist")

    let data = try Data(contentsOf: url)
    let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
    return try XCTUnwrap(plist as? [String: Any])
  }

  private var declarations: [AppletTypeDeclaration] { BuiltInApplets.declarations }

  /// Catches an applet that declares a type the app never registers with Launch Services, a type
  /// registered with no applet behind it, a rank above Alternate that would displace another app,
  /// and a role other than Viewer. The plist is the app's real one.
  ///
  /// The plist rank is always Alternate, whatever rank the applet declares, so a change to a
  /// declared rank is not drift by design.
  func testTheAppsDocumentTypesMatchTheAppletDeclarations() throws {
    let plist = try loadPlist()

    XCTAssertEqual(DocumentTypeManifest.problems(in: plist, declarations: declarations), [])

    for entry in DocumentTypeManifest.documentTypes(in: plist) {
      XCTAssertEqual(entry["CFBundleTypeRole"] as? String, "Viewer")
    }
  }

  /// Catches a plist whose imports disagree with the catalog. The audit takes its table from the
  /// plist, so a declared type that the system lacks must be imported there with a conformance.
  func testTheCatalogAuditPassesAgainstThePlistsImportedTypes() throws {
    let imported = DocumentTypeManifest.importedTypes(in: try loadPlist())

    XCTAssertEqual(
      CatalogAudit.problems(
        in: declarations, types: SystemContentTypes(), imported: imported), [])
  }

  // MARK: The checker can fail

  private func entry(types: [String], rank: String?) -> [String: Any] {
    var entry: [String: Any] = [
      "CFBundleTypeName": "Test", "LSItemContentTypes": types,
    ]

    if let rank { entry["LSHandlerRank"] = rank }

    return entry
  }

  private var allDeclared: [String] {
    declarations.flatMap { $0.opens.map(\.identifier) }
  }

  func testAnOwnerRankIsReported() {
    let plist: [String: Any] = [
      "CFBundleDocumentTypes": [entry(types: allDeclared, rank: "Owner")]
    ]

    XCTAssertEqual(
      DocumentTypeManifest.problems(in: plist, declarations: declarations),
      [.rankNotAlternate(entry: "Test", rank: "Owner")])
  }

  func testAMissingRankIsReported() {
    let plist: [String: Any] = [
      "CFBundleDocumentTypes": [entry(types: allDeclared, rank: nil)]
    ]

    XCTAssertEqual(
      DocumentTypeManifest.problems(in: plist, declarations: declarations),
      [.rankNotAlternate(entry: "Test", rank: nil)])
  }

  func testADeclaredTypeWithNoEntryAndAnEntryWithNoApplet() {
    let plist: [String: Any] = [
      "CFBundleDocumentTypes": [entry(types: ["public.png"], rank: "Alternate")]
    ]

    XCTAssertEqual(
      DocumentTypeManifest.problems(in: plist, declarations: declarations),
      [
        .undeclared(type: "public.comma-separated-values-text"),
        .undeclared(type: "public.folder"), .undeclared(type: "public.json"),
        .unclaimed(type: "public.png"),
      ])
  }

  func testAPlistWithNoDocumentTypesReportsEveryDeclaredType() {
    XCTAssertEqual(
      DocumentTypeManifest.problems(in: [:], declarations: declarations),
      [
        .undeclared(type: "public.comma-separated-values-text"),
        .undeclared(type: "public.folder"), .undeclared(type: "public.json"),
      ])
  }

  /// Catches an import read wrongly. The table maps each imported identifier to its conformances.
  func testImportedTypesAreReadWithTheirConformances() {
    let plist: [String: Any] = [
      "UTImportedTypeDeclarations": [
        ["UTTypeIdentifier": "org.example.geo", "UTTypeConformsTo": ["public.json"]],
        ["UTTypeIdentifier": "org.example.bare"],
      ]
    ]

    XCTAssertEqual(
      DocumentTypeManifest.importedTypes(in: plist),
      ["org.example.geo": ["public.json"], "org.example.bare": []])
  }
}
