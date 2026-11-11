// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "onwin",
    // Russian is the source language of the interface; translations live in each target's
    // Localizable.xcstrings (compiled by the CompileStringCatalogs plugin, see scripts/l10n.py).
    defaultLocalization: "ru",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OnwinCore", targets: ["OnwinCore"]),
        .executable(name: "onwinctl", targets: ["onwinctl"]),
        .executable(name: "Onwin", targets: ["OnwinApp"]),
        .executable(name: "onwin-launcher", targets: ["onwin-launcher"]),
    ],
    targets: [
        // Everything that does real work: engines, spaces, launching, graphics, recipes.
        .target(name: "OnwinCore", exclude: ["Localizable.xcstrings"], plugins: ["CompileStringCatalogs"]),
        // Command line tool: create spaces, install and run programs, manage engines and components.
        .executableTarget(name: "onwinctl", dependencies: ["OnwinCore"],
                          exclude: ["Localizable.xcstrings"], plugins: ["CompileStringCatalogs"]),
        // SwiftUI application.
        .executableTarget(name: "OnwinApp", dependencies: ["OnwinCore"],
                          exclude: ["Localizable.xcstrings", "InfoPlist.xcstrings"], plugins: ["CompileStringCatalogs"]),
        // Main executable of the per-program launcher .app bundles (LauncherBuilder copies it).
        // No OnwinCore dependency: it stays small and only hands onwin://run URLs to onwin.
        .executableTarget(name: "onwin-launcher"),
        // String Catalogs → .lproj at build time (the Command Line Tools cannot compile .xcstrings).
        .executableTarget(name: "xcstrings-compile", path: "Sources/xcstrings-compile"),
        .plugin(name: "CompileStringCatalogs", capability: .buildTool(), dependencies: ["xcstrings-compile"]),
    ]
)
