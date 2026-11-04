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
  ],
  targets: [
    .target(name: "Theme"),
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
    .target(name: "AppletCatalog", dependencies: ["AppletKit", "TerminalApplet"]),
    .testTarget(name: "StatusKitTests", dependencies: ["StatusKit"]),
    .testTarget(name: "FileRoutingTests", dependencies: ["FileRouting", "AppletKit"]),
    .testTarget(
      name: "AppletCatalogTests",
      dependencies: ["AppletCatalog", "FileRouting", "AppletKit", "WindowKit"]),
    .testTarget(name: "PaneModelTests", dependencies: ["PaneModel"]),
    .testTarget(name: "AppletKitTests", dependencies: ["AppletKit"]),
    .testTarget(name: "LayoutKitTests", dependencies: ["LayoutKit", "AppletKit", "PaneModel"]),
    .testTarget(
      name: "TerminalAppletTests",
      dependencies: [
        "TerminalApplet", "AppletKit", "StatusKit", "TerminalSurface", "Theme", "WindowKit",
        "Preferences",
      ]),
    .testTarget(name: "SettingsKitTests", dependencies: ["SettingsKit", "Preferences"]),
    .testTarget(name: "ThemeTests", dependencies: ["Theme"]),
    .testTarget(name: "PreferencesTests", dependencies: ["Preferences"]),
    .testTarget(name: "TerminalSurfaceTests", dependencies: ["TerminalSurface", "Theme"]),
    .testTarget(
      name: "WindowKitTests",
      dependencies: [
        "WindowKit", "Theme", "Preferences", "StatusKit", "AppletKit", "PaneModel", "LayoutKit",
        "FileRouting",
      ]),
  ],
  swiftLanguageModes: [.v6]
)
