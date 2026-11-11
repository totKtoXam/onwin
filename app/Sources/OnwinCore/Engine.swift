import Foundation
import Darwin

/// A Wine engine: a Wine install tree built from the CrossOver sources.
///
///     <root>/bin/wine, bin/wineserver
///     <root>/lib/wine/{x86_64-unix,x86_64-windows,i386-windows}
///     <root>/lib/dxvk/{x86_64-windows,i386-windows}         (DXVK for MoltenVK)
///     <root>/lib/dxmt/{x86_64-unix,x86_64-windows,i386-windows}
///     <root>/lib/external/                                   (MoltenVK, freetype, gnutls, ...)
///     <root>/share/wine/
///     <root>/onwin-engine.json
public struct Engine: Identifiable, Hashable, Sendable {
    public struct Info: Codable, Hashable, Sendable {
        public var id: String
        public var displayName: String
        public var wineVersion: String
        public var crossoverSourceVersion: String?
        public var built: Date?
    }

    public let root: URL
    public let info: Info

    public var id: String { info.id }
    public var bin: URL { root.appendingPathComponent("bin") }
    public var wine: URL { bin.appendingPathComponent("wine") }
    public var wineserver: URL { bin.appendingPathComponent("wineserver") }
    public var lib: URL { root.appendingPathComponent("lib") }
    public var wineLib: URL { lib.appendingPathComponent("wine") }
    public var externalLib: URL { lib.appendingPathComponent("external") }
    public var dxvkDir: URL { lib.appendingPathComponent("dxvk") }
    public var dxmtDir: URL { lib.appendingPathComponent("dxmt") }

    public var hasDXVK: Bool { OnwinPaths.exists(dxvkDir.appendingPathComponent("x86_64-windows/d3d11.dll")) }
    public var hasDXMT: Bool { OnwinPaths.exists(dxmtDir.appendingPathComponent("x86_64-windows/d3d11.dll")) }
    public var hasMoltenVK: Bool { OnwinPaths.exists(externalLib.appendingPathComponent("libMoltenVK.dylib")) }

    /// Wine Mono and Wine Gecko shipped inside the engine (share/wine/{mono,gecko}).
    /// Wine then uses these shared copies directly: no installer dialog, nothing to download.
    public var hasBundledAddons: Bool {
        func hasEntry(_ dir: String, prefix: String) -> Bool {
            let url = root.appendingPathComponent("share/wine/\(dir)")
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            return entries.contains { $0.hasPrefix(prefix) }
        }
        return hasEntry("mono", prefix: "wine-mono-") && hasEntry("gecko", prefix: "wine-gecko-")
    }

    /// DLL overrides for wineboot runs: disable mscoree/mshtml only when the engine has no bundled
    /// Mono/Gecko (otherwise their registration would open the download dialogs).
    public var addonInstallOverrides: [String: String] {
        hasBundledAddons ? [:] : ["mscoree": "", "mshtml": ""]
    }

    public init(root: URL) throws {
        self.root = root
        let wine = root.appendingPathComponent("bin/wine")
        guard OnwinPaths.exists(wine) else {
            throw OnwinError("В \(root.path) нет bin/wine — это не движок Wine")
        }
        let infoURL = root.appendingPathComponent("onwin-engine.json")
        if let data = try? Data(contentsOf: infoURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let decoded = try? decoder.decode(Info.self, from: data) {
                self.info = decoded
                return
            }
        }
        let name = root.lastPathComponent
        self.info = Info(id: name, displayName: name, wineVersion: "unknown", crossoverSourceVersion: nil, built: nil)
    }
}

/// Finds installed engines. Search order:
/// 1. `ONWIN_ENGINE` environment variable (path to an engine root) — development override;
/// 2. the engine bundled inside Onwin.app (`Contents/SharedSupport/Engine`);
/// 3. `~/Library/Application Support/onwin/Engines/*`.
public enum EngineManager {
    public static func installedEngines() -> [Engine] {
        var result: [Engine] = []
        var seen = Set<String>()
        func add(_ url: URL) {
            guard let engine = try? Engine(root: url), !seen.contains(engine.root.standardizedFileURL.path) else { return }
            seen.insert(engine.root.standardizedFileURL.path)
            result.append(engine)
        }
        if let custom = ProcessInfo.processInfo.environment["ONWIN_ENGINE"], !custom.isEmpty {
            add(URL(fileURLWithPath: (custom as NSString).expandingTildeInPath))
        }
        if let shared = Bundle.main.sharedSupportURL {
            add(shared.appendingPathComponent("Engine"))
        }
        let dirs = (try? FileManager.default.contentsOfDirectory(at: OnwinPaths.engines,
                                                                 includingPropertiesForKeys: nil,
                                                                 options: [.skipsHiddenFiles])) ?? []
        for dir in dirs.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            add(dir)
        }
        return result
    }

    public static var defaultEngineID: String? {
        get { Settings.load().defaultEngineID }
        set { var s = Settings.load(); s.defaultEngineID = newValue; try? s.save() }
    }

    /// Engine to use for a space: its pinned engine if present, otherwise the default, otherwise the first one.
    public static func engine(for config: SpaceConfig?) throws -> Engine {
        let engines = installedEngines()
        if let wanted = config?.engineID, let match = engines.first(where: { $0.id == wanted }) {
            return match
        }
        if let def = defaultEngineID, let match = engines.first(where: { $0.id == def }) {
            return match
        }
        if let first = engines.first { return first }
        throw OnwinError("Движок Wine не установлен. Соберите его (engine/build.sh) или установите в \(OnwinPaths.engines.path)")
    }

    /// The DMG build ships the engine inside Onwin.app. When the DMG was downloaded in a browser, macOS
    /// puts `com.apple.quarantine` on every file in it; approving Onwin.app in Gatekeeper clears only the
    /// app itself, and Wine's own executables and libraries inside would still be checked and refused.
    /// The user already chose to run onwin, so drop the flag from the bundled engine (once; a no-op
    /// when the flag is absent or the bundle is read-only, e.g. still on the disk image).
    public static func clearQuarantineOfBundledEngine() {
        guard let engine = Bundle.main.sharedSupportURL?.appendingPathComponent("Engine", isDirectory: true) else { return }
        let wine = engine.appendingPathComponent("bin/wine").path
        guard getxattr(wine, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0 else { return }
        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-dr", "com.apple.quarantine", engine.path]
        try? xattr.run()
        xattr.waitUntilExit()
    }

    /// Copies (or moves) a built engine tree into the Engines directory.
    @discardableResult
    public static func install(from source: URL, move: Bool = false) throws -> Engine {
        let engine = try Engine(root: source)
        try OnwinPaths.ensureLayout()
        let destination = OnwinPaths.engines.appendingPathComponent(engine.id, isDirectory: true)
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        if move {
            try fm.moveItem(at: source, to: destination)
        } else {
            try fm.copyItem(at: source, to: destination)
        }
        return try Engine(root: destination)
    }
}

/// Global application settings.
public struct Settings: Codable, Sendable {
    public var defaultEngineID: String?
    public var defaultBackend: GraphicsBackend = .auto
    /// «Устанавливать нужные компоненты автоматически»: before the first run of a program and after a
    /// run that failed for a missing library (AutoComponents.swift). A space may override it
    /// (`SpaceConfig.autoInstallComponents`).
    public var autoInstallComponents = true

    public init() {}

    private enum CodingKeys: String, CodingKey { case defaultEngineID, defaultBackend, autoInstallComponents }

    // Tolerant decoding: a settings file written before a key existed keeps its other values.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        defaultEngineID = try? c.decodeIfPresent(String.self, forKey: .defaultEngineID)
        defaultBackend = (try? c.decodeIfPresent(GraphicsBackend.self, forKey: .defaultBackend)) ?? .auto
        autoInstallComponents = (try? c.decodeIfPresent(Bool.self, forKey: .autoInstallComponents)) ?? true
    }

    public static func load() -> Settings {
        guard let data = try? Data(contentsOf: OnwinPaths.settingsFile),
              let s = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
        return s
    }

    public func save() throws {
        try OnwinPaths.ensureLayout()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: OnwinPaths.settingsFile, options: .atomic)
    }
}
