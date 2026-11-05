import AppletCatalog
import AppletKit
import FileRouting
import XCTest

/// Proves the production catalog against the system's real type database. The Info.plist drift
/// check joins it when the app declares document types.
final class BuiltInAppletsTests: XCTestCase {
  /// Catches a declaration that changes without a deliberate edit here. The terminal opens folders
  /// as the owner, the data viewer opens CSV, JSON, and `.xlsx` as the owner, and the map viewer
  /// opens no type yet.
  func testTheCatalogIsTheTerminalOpeningFoldersAndTheDataViewerOpeningTables() {
    XCTAssertEqual(
      BuiltInApplets.declarations,
      [
        AppletTypeDeclaration(
          typeID: "terminal", displayName: "Terminal",
          opens: [OpenedType("public.folder", rank: .owner)]),
        AppletTypeDeclaration(
          typeID: "data-viewer", displayName: "Data Viewer",
          opens: [
            OpenedType("public.comma-separated-values-text", rank: .owner),
            OpenedType("public.json", rank: .owner),
            OpenedType("org.openxmlformats.spreadsheetml.sheet", rank: .owner),
          ]),
        AppletTypeDeclaration(typeID: "map-viewer", displayName: "Map Viewer", opens: []),
      ])
  }

  /// Catches a table file that routes anywhere but the data viewer, or a router that cannot type a
  /// real `.csv`, `.json`, or `.xlsx` file. The file stays in its own folder.
  func testTableFilesRouteToTheDataViewer() throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }

    let router = FileRouter(declarations: BuiltInApplets.declarations)

    for (name, type) in [
      ("a.csv", "public.comma-separated-values-text"), ("a.json", "public.json"),
      ("a.xlsx", "org.openxmlformats.spreadsheetml.sheet"),
    ] {
      let file = folder.appendingPathComponent(name)
      try Data("x,y\n1,2\n".utf8).write(to: file)

      XCTAssertEqual(
        router.decide(file),
        .open(file: file, appletTypeID: "data-viewer", startDirectory: folder.path, type: type),
        name)
    }
  }

  /// Catches two equal claims, an undeclared type, or a `public.directory` declaration in the
  /// shipped catalog.
  func testTheCatalogPassesTheAuditAgainstTheSystem() {
    XCTAssertEqual(
      CatalogAudit.problems(in: BuiltInApplets.declarations, types: SystemContentTypes()), [])
  }

  /// Catches a folder that routes anywhere but the terminal, started in the folder itself.
  func testAFolderRoutesToTheTerminalAtItself() throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }

    let router = FileRouter(declarations: BuiltInApplets.declarations)

    XCTAssertEqual(
      router.decide(folder),
      .open(
        file: folder, appletTypeID: "terminal", startDirectory: folder.path, type: "public.folder")
    )
  }

  /// Catches a package taken for a folder. A bundle conforms to `public.directory` and not to
  /// `public.folder`, so the router refuses it as unsupported.
  func testAPackageIsRefusedAsUnsupported() throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }

    let bundle = folder.appendingPathComponent("Thing.app", isDirectory: true)
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)

    let router = FileRouter(declarations: BuiltInApplets.declarations)

    guard case .refused(_, .unsupported(let type)) = router.decide(bundle) else {
      return XCTFail("expected the package to be refused")
    }

    XCTAssertEqual(type, "com.apple.application-bundle")
  }

  private func makeFolder() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("uniterm-catalog-\(UUID().uuidString)", isDirectory: true)
      .resolvingSymlinksInPath()

    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
