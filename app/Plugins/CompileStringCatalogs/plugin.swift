import Foundation
import PackagePlugin

/// Compiles the target's String Catalog (`Localizable.xcstrings`, Apple's format) into
/// `<language>.lproj/Localizable.strings` + `.stringsdict`, which SwiftPM then bundles as
/// localized resources.
///
/// Why a plugin: `swift build` with only the Command Line Tools copies an `.xcstrings` file as is
/// (compiling it needs `xcstringstool` from full Xcode), and Foundation does not read catalogs at
/// run time. The catalog stays the single source of truth; edit it in Xcode or with
/// `scripts/l10n.py` (which also adds new keys extracted by the compiler).
@main
struct CompileStringCatalogs: BuildToolPlugin {
    /// Languages the app ships. Keep in sync with `OnwinLanguages.all` (OnwinCore/Localization.swift),
    /// CFBundleLocalizations in scripts/build-app.sh and LANGUAGES in scripts/l10n.py.
    static let languages = ["ru", "en", "zh-Hans", "kk"]

    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        guard let target = target as? SourceModuleTarget else { return [] }
        // The catalogs are `exclude`d in Package.swift (so SwiftPM does not copy the raw JSON), hence
        // they are found in the target folder rather than in `sourceFiles`.
        let catalogs = try FileManager.default
            .contentsOfDirectory(atPath: target.directory.string)
            .filter { $0.hasSuffix(".xcstrings") }
            .sorted()
            .map { target.directory.appending($0) }
        guard !catalogs.isEmpty else { return [] }
        let output = context.pluginWorkDirectory.appending("Localization")
        var outputs: [Path] = []
        for catalog in catalogs {
            let table = catalog.stem
            for language in Self.languages {
                let lproj = output.appending("\(language).lproj")
                outputs.append(lproj.appending("\(table).strings"))
                outputs.append(lproj.appending("\(table).stringsdict"))
            }
        }
        return [
            .buildCommand(
                displayName: "Compiling string catalogs of \(target.name)",
                executable: try context.tool(named: "xcstrings-compile").path,
                arguments: [output.string, Self.languages.joined(separator: ",")] + catalogs.map(\.string),
                inputFiles: catalogs,
                outputFiles: outputs
            ),
        ]
    }
}
