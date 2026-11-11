import Foundation

// Interface languages. Russian is the source language (the keys of every Localizable.xcstrings);
// English, Simplified Chinese and Kazakh are translations. How it fits together:
//
//   Sources/<target>/Localizable.xcstrings   String Catalog per target (OnwinCore, OnwinApp, onwinctl)
//   Plugins/CompileStringCatalogs            compiles them into <lang>.lproj at build time
//   scripts/l10n.py                          adds new keys extracted by the compiler, checks translations
//   scripts/build-app.sh                     OnwinApp's .lproj → Onwin.app/Contents/Resources (Bundle.main,
//                                            used by SwiftUI Text("…")); the other resource bundles → Resources
//
// In code: SwiftUI literals (Text("…"), Button("…")…) are already localized. Anything typed `String`
// goes through String(localized: "…") in OnwinApp, String(localized: "…", bundle: .onwinCore) here and
// String(localized: "…", bundle: .onwinctl) in onwinctl. Plurals: a key with %lld and plural variations
// in the catalog.

/// The languages onwin's interface is translated into.
public enum OnwinLanguage: String, CaseIterable, Identifiable, Sendable {
    case russian = "ru"
    case english = "en"
    case chinese = "zh-Hans"
    case kazakh = "kk"

    public var id: String { rawValue }

    /// The language's own name; the same in every interface language.
    public var nativeName: String {
        switch self {
        case .russian: return "Русский"
        case .english: return "English"
        case .chinese: return "中文"
        case .kazakh: return "Қазақша"
        }
    }

    /// The language chosen in onwin's settings (nil: follow the system), stored like macOS stores the
    /// per-app language from System Settings: AppleLanguages in onwin's own defaults domain.
    /// Takes effect at the next launch.
    public static var appOverride: OnwinLanguage? {
        get {
            guard let first = UserDefaults.standard.persistentDomain(forName: OnwinLanguage.appDomain)?["AppleLanguages"]
                as? [String] else { return nil }
            return first.first.flatMap(OnwinLanguage.matching)
        }
        set {
            var domain = UserDefaults.standard.persistentDomain(forName: OnwinLanguage.appDomain) ?? [:]
            if let newValue {
                domain["AppleLanguages"] = [newValue.rawValue]
            } else {
                domain.removeValue(forKey: "AppleLanguages")
            }
            UserDefaults.standard.setPersistentDomain(domain, forName: OnwinLanguage.appDomain)
        }
    }

    /// The language the interface is shown in right now.
    public static var current: OnwinLanguage {
        Bundle.onwinCore.preferredLocalizations.first.flatMap(matching) ?? .russian
    }

    /// "en-GB" → .english, "zh-Hans-CN" → .chinese, "kk-KZ" → .kazakh.
    public static func matching(_ identifier: String) -> OnwinLanguage? {
        let lower = identifier.lowercased()
        if lower.hasPrefix("zh") { return lower.hasPrefix("zh-hant") || lower.hasPrefix("zh-tw") || lower.hasPrefix("zh-hk") ? nil : .chinese }
        let code = lower.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? lower
        return allCases.first { $0.rawValue == code }
    }

    /// onwin's defaults domain (the app's bundle identifier; onwinctl inside the app shares it).
    static let appDomain = "app.onwin.Onwin"
}

/// Finds SwiftPM resource bundles in an assembled Onwin.app (Contents/Resources), next to the
/// executable (`swift build` output, onwinctl), or through a symlink to onwinctl. SwiftPM's own
/// `Bundle.module` looks only at the root of the .app (where code signing forbids files) and at the
/// absolute build path, and crashes when neither exists — so onwin never uses it.
public enum OnwinResources {
    public static func bundle(named name: String) -> Bundle {
        let file = "onwin_\(name).bundle"
        var folders: [URL] = []
        if let resources = Bundle.main.resourceURL { folders.append(resources) }
        if let executable = Bundle.main.executableURL {
            for url in [executable, executable.resolvingSymlinksInPath()] {
                let dir = url.deletingLastPathComponent()
                folders.append(dir)
                folders.append(dir.deletingLastPathComponent().appending(path: "Resources"))
            }
        }
        folders.append(Bundle.main.bundleURL)
        for folder in folders {
            if let bundle = Bundle(url: folder.appending(path: file)) { return bundle }
        }
        // No translations found: lookups return the keys, i.e. the Russian source text.
        return Bundle.main
    }
}

extension Bundle {
    /// OnwinCore's translations: `String(localized: "…", bundle: .onwinCore)`.
    public static let onwinCore = OnwinResources.bundle(named: "OnwinCore")
}
