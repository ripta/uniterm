// swift-tools-version: 6.2

import Foundation
import PackageDescription

// The terminal surface module is the only target that may depend on GhosttyKit. The path is fixed.
// scripts/build-ghostty.sh points it at the current keyed artifact.
let ghosttyKitPath = "Frameworks/GhosttyKit.xcframework"
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

if !FileManager.default.fileExists(atPath: packageRoot.appending(path: ghosttyKitPath).path) {
  fatalError(
    "GhosttyKit.xcframework is missing at Packages/UnitermKit/\(ghosttyKitPath). Run `make build`.")
}

let package = Package(
  name: "UnitermKit",
  platforms: [.macOS("26.0")],
  products: [
    .library(name: "ThemeCore", targets: ["ThemeCore"]),
    .library(name: "Theme", targets: ["Theme"]),
    .library(name: "Preferences", targets: ["Preferences"]),
    .library(name: "PaneModel", targets: ["PaneModel"]),
    .library(name: "LayoutKit", targets: ["LayoutKit"]),
    .library(name: "WindowKit", targets: ["WindowKit"]),
    .library(name: "SettingsKit", targets: ["SettingsKit"]),
    .library(name: "TerminalSurface", targets: ["TerminalSurface"]),
    .library(name: "StatusKit", targets: ["StatusKit"]),
    .library(name: "AppletKit", targets: ["AppletKit"]),
    .library(name: "TerminalApplet", targets: ["TerminalApplet"]),
    .library(name: "FileRouting", targets: ["FileRouting"]),
    .library(name: "AppletCatalog", targets: ["AppletCatalog"]),
    .library(name: "SourceAccess", targets: ["SourceAccess"]),
    .library(name: "TableData", targets: ["TableData"]),
    .library(name: "DataViewerApplet", targets: ["DataViewerApplet"]),
    .library(name: "GeoData", targets: ["GeoData"]),
    .library(name: "MapViewerApplet", targets: ["MapViewerApplet"]),
    .library(name: "PlaceSearch", targets: ["PlaceSearch"]),
    .library(name: "BrowserModel", targets: ["BrowserModel"]),
    .library(name: "BrowserApplet", targets: ["BrowserApplet"]),
    .library(name: "ImageDecoding", targets: ["ImageDecoding"]),
    .library(name: "ImageViewerApplet", targets: ["ImageViewerApplet"]),
  ],
  dependencies: [
    // The first third-party Swift package. Only TableData uses it. The version is exact, and
    // Package.resolved is committed beside this file and in the Xcode workspace.
    .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20")
  ],
  targets: [
    // The palette's tokens, flavors, color values, and color math, with no AppKit. GeoData reads the
    // accent set from it. Theme adds the AppKit colors and re-exports it, so `import Theme` still
    // sees every name.
    .target(name: "ThemeCore"),
    .target(name: "Theme", dependencies: ["ThemeCore"]),
    .target(name: "Preferences"),
    .target(name: "StatusKit"),
    .target(name: "AppletKit", dependencies: ["StatusKit", "Theme"]),
    .target(name: "PaneModel"),
    .target(name: "LayoutKit", dependencies: ["AppletKit", "PaneModel"]),
    .target(name: "FileRouting", dependencies: ["AppletKit"]),
    .target(
      name: "WindowKit",
      dependencies: [
        "Theme", "Preferences", "AppletKit", "StatusKit", "PaneModel", "LayoutKit", "FileRouting",
        "GeoData", "PlaceSearch",
      ]),
    .target(name: "SettingsKit", dependencies: ["Preferences"]),
    .binaryTarget(name: "GhosttyKit", path: ghosttyKitPath),
    .target(
      name: "TerminalSurface",
      dependencies: ["GhosttyKit", "Theme"],
      // ghostty.h is an umbrella header that leaves out the headers beside it in the xcframework.
      // The artifact stays as Ghostty built it, so the warning is silenced here.
      swiftSettings: [.unsafeFlags(["-Xcc", "-Wno-incomplete-umbrella"])],
      // The static library needs the C++ runtime and the system frameworks that Ghostty's own
      // app links. A binary target carries no link settings.
      linkerSettings: [
        .linkedLibrary("c++"),
        .linkedFramework("Carbon"),
        .linkedFramework("Metal"),
        .linkedFramework("QuartzCore"),
        .linkedFramework("CoreText"),
        .linkedFramework("CoreGraphics"),
        .linkedFramework("IOSurface"),
        .linkedFramework("AppKit"),
      ]),
    .target(
      name: "TerminalApplet", dependencies: ["AppletKit", "StatusKit", "TerminalSurface", "Theme"]),
    // Reaching a file for a viewer: the stored path and bookmark, and the errors for a missing,
    // protected, or irregular file. It has no AppKit, so the table and map targets share it.
    .target(name: "SourceAccess"),
    .target(
      name: "TableData",
      dependencies: ["SourceAccess", .product(name: "ZIPFoundation", package: "ZIPFoundation")]),
    .target(
      name: "DataViewerApplet",
      dependencies: ["AppletKit", "SourceAccess", "StatusKit", "TableData", "Theme"]),
    // The map's pure model. It has no AppKit and no MapKit, so the region and style rules test
    // without a map view.
    .target(name: "GeoData", dependencies: ["ThemeCore"]),
    // Finding and naming places through Apple Maps, and the search field the launcher and the map
    // share. Every service sits behind a protocol, so tests never reach the network.
    .target(name: "PlaceSearch", dependencies: ["GeoData", "Theme"]),
    .target(
      name: "MapViewerApplet",
      dependencies: ["AppletKit", "GeoData", "PlaceSearch", "SourceAccess", "StatusKit", "Theme"]),
    // The browser's pure rules: which URL schemes load from which source, where a scheme-less
    // address goes, and the description payload. It has no AppKit and no WebKit, so the policy
    // tests without a web view.
    .target(name: "BrowserModel"),
    .target(
      name: "BrowserApplet",
      dependencies: ["AppletKit", "BrowserModel", "Preferences", "StatusKit", "Theme"]),
    // The image helper's decode-only wire format: framing, the protocol version, the named output
    // color spaces, and the checks on sizes. It has no AppKit and no ImageIO, so the app and the
    // helper share one codec and the fuzzers can reach it alone.
    .target(name: "ImageWire"),
    // The helper side of image viewing. It is the only code that calls ImageIO.
    .target(name: "ImageDecoding", dependencies: ["ImageWire"]),
    // A thin main over ImageDecoding, so the supervisor's tests can run a helper without the App
    // Sandbox. The shipped helper is the Xcode target of the same name.
    .executableTarget(name: "ImageDecoderHelper", dependencies: ["ImageDecoding"]),
    // The image viewer's pure rules: folder listing and order, the request scheduler, the
    // budgets, and fit math. It has no AppKit and no ImageIO.
    .target(name: "ImageViewerModel", dependencies: ["ImageWire", "SourceAccess"]),
    .target(
      name: "ImageViewerApplet",
      dependencies: [
        "AppletKit", "ImageViewerModel", "ImageWire", "SourceAccess", "StatusKit", "Theme",
      ]),
    .target(
      name: "AppletCatalog",
      dependencies: [
        "AppletKit", "BrowserApplet", "DataViewerApplet", "ImageViewerApplet", "MapViewerApplet",
        "TerminalApplet",
      ]),
    .testTarget(name: "StatusKitTests", dependencies: ["StatusKit"]),
    .testTarget(name: "FileRoutingTests", dependencies: ["FileRouting", "AppletKit"]),
    .testTarget(
      name: "AppletCatalogTests",
      dependencies: [
        "AppletCatalog", "FileRouting", "AppletKit", "WindowKit", "BrowserApplet", "Preferences",
        "BrowserTestSupport",
      ]),
    // Test support. It builds ZIP archives for the tests of both targets that read workbooks, and
    // holds the seeded generator the table and map fuzzers share.
    .target(name: "TableTestSupport", path: "Tests/TableTestSupport"),
    // The recording host the applet tests share, so each applet's tests read one set of deliveries.
    .target(
      name: "AppletTestSupport", dependencies: ["AppletKit", "StatusKit"],
      path: "Tests/AppletTestSupport"),
    // A local HTTP server for the browser's tests, so a web view loads real pages from a real
    // socket and no test reaches the network.
    .target(name: "BrowserTestSupport", path: "Tests/BrowserTestSupport"),
    .testTarget(name: "TableDataTests", dependencies: ["TableData", "TableTestSupport"]),
    .testTarget(
      name: "DataViewerAppletTests",
      dependencies: [
        "DataViewerApplet", "TableData", "AppletKit", "StatusKit", "Theme", "TableTestSupport",
        "AppletTestSupport",
      ]),
    .testTarget(name: "SourceAccessTests", dependencies: ["SourceAccess"]),
    .testTarget(name: "GeoDataTests", dependencies: ["GeoData", "ThemeCore"]),
    .testTarget(name: "PlaceSearchTests", dependencies: ["PlaceSearch", "GeoData", "Theme"]),
    .testTarget(
      name: "MapViewerAppletTests",
      dependencies: [
        "MapViewerApplet", "GeoData", "AppletKit", "PlaceSearch", "SourceAccess", "StatusKit",
        "Theme", "TableTestSupport", "AppletTestSupport",
      ]),
    .testTarget(name: "BrowserModelTests", dependencies: ["BrowserModel"]),
    // Generates image files in code for the image tests, and finds the unsandboxed helper that
    // SwiftPM builds beside the test bundle.
    .target(name: "ImageTestSupport", path: "Tests/ImageTestSupport"),
    .testTarget(name: "ImageWireTests", dependencies: ["ImageWire", "TableTestSupport"]),
    .testTarget(
      name: "ImageDecodingTests",
      dependencies: ["ImageDecoding", "ImageWire", "ImageTestSupport"]),
    .testTarget(
      name: "ImageViewerModelTests",
      dependencies: ["ImageViewerModel", "ImageWire", "SourceAccess", "ImageTestSupport"]),
    .testTarget(
      name: "ImageViewerAppletTests",
      dependencies: [
        "ImageViewerApplet", "ImageViewerModel", "ImageWire", "ImageDecoding", "ImageDecoderHelper",
        "AppletKit",
        "StatusKit", "Theme", "SourceAccess", "AppletTestSupport", "ImageTestSupport",
      ]),
    .testTarget(
      name: "BrowserAppletTests",
      dependencies: [
        "BrowserApplet", "BrowserModel", "AppletKit", "Preferences", "StatusKit", "Theme",
        "BrowserTestSupport", "AppletTestSupport",
      ]),
    .testTarget(name: "PaneModelTests", dependencies: ["PaneModel"]),
    .testTarget(name: "AppletKitTests", dependencies: ["AppletKit", "AppletTestSupport"]),
    .testTarget(name: "LayoutKitTests", dependencies: ["LayoutKit", "AppletKit", "PaneModel"]),
    .testTarget(
      name: "TerminalAppletTests",
      dependencies: [
        "TerminalApplet", "AppletKit", "StatusKit", "TerminalSurface", "Theme", "WindowKit",
        "Preferences", "AppletTestSupport",
      ]),
    .testTarget(name: "SettingsKitTests", dependencies: ["SettingsKit", "Preferences"]),
    .testTarget(name: "ThemeTests", dependencies: ["Theme"]),
    .testTarget(name: "PreferencesTests", dependencies: ["Preferences"]),
    .testTarget(name: "TerminalSurfaceTests", dependencies: ["TerminalSurface", "Theme"]),
    .testTarget(
      name: "WindowKitTests",
      dependencies: [
        "WindowKit", "Theme", "Preferences", "StatusKit", "AppletKit", "PaneModel", "LayoutKit",
        "FileRouting", "GeoData", "PlaceSearch",
      ]),
  ],
  swiftLanguageModes: [.v6]
)
