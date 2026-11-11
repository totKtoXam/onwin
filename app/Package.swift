// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "onwin",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OnwinCore", targets: ["OnwinCore"]),
        .executable(name: "onwinctl", targets: ["onwinctl"]),
        .executable(name: "Onwin", targets: ["OnwinApp"]),
        .executable(name: "onwin-launcher", targets: ["onwin-launcher"]),
    ],
    targets: [
        // Everything that does real work: engines, spaces, launching, graphics, recipes.
        .target(name: "OnwinCore"),
        // Command line tool: create spaces, install and run programs, manage engines and components.
        .executableTarget(name: "onwinctl", dependencies: ["OnwinCore"]),
        // SwiftUI application.
        .executableTarget(name: "OnwinApp", dependencies: ["OnwinCore"]),
        // Main executable of the per-program launcher .app bundles (LauncherBuilder copies it).
        // No OnwinCore dependency: it stays small and only hands onwin://run URLs to onwin.
        .executableTarget(name: "onwin-launcher"),
    ]
)
