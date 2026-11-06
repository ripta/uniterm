import AppletKit
import FileRouting
import XCTest

/// Proves the catalog checks fail on the faults they name. The plist drift check that feeds
/// `imported` from the host's `Info.plist` is a separate test.
final class CatalogAuditTests: XCTestCase {
  func testACleanCatalogHasNoProblems() {
    let catalog = [
      applet("a", [("public.text", .owner)]), applet("b", [("public.text", .alternate)]),
    ]

    XCTAssertEqual(CatalogAudit.problems(in: catalog, types: FixtureTypes.standard()), [])
  }

  /// Catches two applets claiming one type at one rank, which only a silent tiebreak could settle.
  func testTwoAppletsAtTheSameRankFail() {
    let catalog = [
      applet("a", [("public.text", .owner)]), applet("b", [("public.text", .owner)]),
    ]

    XCTAssertEqual(
      CatalogAudit.problems(in: catalog, types: FixtureTypes.standard()),
      [.sameRankClaim(type: "public.text", rank: .owner, applets: ["a", "b"])])
  }

  /// Catches a declared type that nothing imports. A file of that type would resolve to a dynamic
  /// type and match no declaration.
  func testADeclaredTypeTheSystemLacksFailsUnlessImportedWithConformance() {
    let catalog = [applet("a", [("com.example.unknown", .owner)])]
    let types = FixtureTypes.standard()

    XCTAssertEqual(
      CatalogAudit.problems(in: catalog, types: types),
      [.unknownType(type: "com.example.unknown", applet: "a")])

    XCTAssertEqual(
      CatalogAudit.problems(
        in: catalog, types: types, imported: ["com.example.unknown": ["public.json"]]), [])

    XCTAssertEqual(
      CatalogAudit.problems(in: catalog, types: types, imported: ["com.example.unknown": []]),
      [.importedWithoutConformance(type: "com.example.unknown", applet: "a")])
  }

  /// Catches a declaration of `public.directory`, which would take a package for a folder.
  func testDeclaringDirectoryFails() {
    let catalog = [applet("a", [("public.directory", .owner)])]

    XCTAssertEqual(
      CatalogAudit.problems(in: catalog, types: FixtureTypes.standard()),
      [.declaresDirectory(applet: "a")])
  }
}
