import Foundation

/// Wine Mono and Wine Gecko as parts of the engine that are downloaded only when a program needs them.
///
/// The engine release (`onwin-engine-<id>.tar.xz`, what install.sh and the first launch download) comes
/// without them: together they are ~95 MB of its ~153 MB, and most games need neither. The offline DMG's
/// engine still has them inside. Wine finds them in `<engine>/share/wine/{mono,gecko}/<folder>` — the same
/// place engine/build.sh (stage addons) puts them (dlls/mscoree/metahost.c `get_mono_path_datadir`,
/// dlls/mshtml/nsembed.c `load_gecko`), so a space uses the shared copy: no installer window, and nothing
/// is installed per space.
///
/// When a program needs one (`AutoComponents` reads its imports: .NET → wine-mono, mshtml → wine-gecko;
/// or its log afterwards), `ComponentInstaller` installs the add-on here once for every space instead of
/// the per-space .msi. Afterwards `share/wine/wine.inf` is touched, so every space is updated once more at
/// its next start (`WineRunner+PrefixUpdate`), now without disabling mscoree / mshtml: their
/// DllRegisterServer registers the .NET / HTML classes in that space.
///
/// Files: the official archives from dl.winehq.org (the same files and SHA-256 as engine/build.sh stage
/// addons). Versions must match Wine exactly (dlls/appwiz.cpl/addons.c): `Catalog.wineMonoVersion`,
/// `Catalog.wineGeckoVersion`.
public enum EngineAddon: String, CaseIterable, Sendable {
    case mono
    case geckoX86
    case geckoX64

    /// Folder under share/wine.
    public var group: String { self == .mono ? "mono" : "gecko" }

    /// The folder Wine looks for (the archive's top folder).
    public var folder: String {
        switch self {
        case .mono: return "wine-mono-\(Catalog.wineMonoVersion)"
        case .geckoX86: return "wine-gecko-\(Catalog.wineGeckoVersion)-x86"
        case .geckoX64: return "wine-gecko-\(Catalog.wineGeckoVersion)-x86_64"
        }
    }

    public var title: String {
        switch self {
        case .mono: return "Wine Mono \(Catalog.wineMonoVersion)"
        case .geckoX86: return "Wine Gecko \(Catalog.wineGeckoVersion) (32 бит)"
        case .geckoX64: return "Wine Gecko \(Catalog.wineGeckoVersion) (64 бит)"
        }
    }

    var archiveName: String { folder + (self == .mono ? "-x86" : "") + ".tar.xz" }

    var url: URL {
        let base = self == .mono ? "wine-mono/\(Catalog.wineMonoVersion)" : "wine-gecko/\(Catalog.wineGeckoVersion)"
        return URL(string: "https://dl.winehq.org/wine/\(base)/\(archiveName)")!
    }

    /// SHA-256 and size of the .tar.xz on dl.winehq.org (checked 11.11.2026; engine/build.sh has the same sums).
    var sha256: String {
        switch self {
        case .mono: return "a16606ef0724202e6a6848ece6e0cbba64d11e2f11aefe744af1d93c6d9f99bb"
        case .geckoX86: return "2cfc8d5c948602e21eff8a78613e1826f2d033df9672cace87fed56e8310afb6"
        case .geckoX64: return "fd88fc7e537d058d7a8abf0c1ebc90c574892a466de86706a26d254710a82814"
        }
    }

    public var size: Int64 {
        switch self {
        case .mono: return 39_590_692
        case .geckoX86: return 43_025_064
        case .geckoX64: return 41_935_496
        }
    }

    public func directory(in engine: Engine) -> URL {
        engine.root.appendingPathComponent("share/wine/\(group)/\(folder)", isDirectory: true)
    }

    public func isInstalled(in engine: Engine) -> Bool {
        OnwinPaths.isDirectory(directory(in: engine))
    }

    /// Gecko is always installed for both architectures: mshtml is registered in the 32- and the 64-bit
    /// half of a space at once, and the missing half would open Wine's «Wine Gecko Installer».
    public static let gecko: [EngineAddon] = [.geckoX86, .geckoX64]
}

public enum EngineAddons {
    /// The add-ons a catalog component stands for (wine-mono, wine-gecko), nil for every other one.
    public static func addons(forComponent id: String) -> [EngineAddon]? {
        switch id {
        case "wine-mono": return [.mono]
        case "wine-gecko": return EngineAddon.gecko
        default: return nil
        }
    }

    public static func missing(_ addons: [EngineAddon], in engine: Engine) -> [EngineAddon] {
        addons.filter { !$0.isInstalled(in: engine) }
    }

    /// Bytes still to download for `addons`.
    public static func downloadSize(_ addons: [EngineAddon], in engine: Engine) -> Int64 {
        missing(addons, in: engine).reduce(0) { $0 + $1.size }
    }

    /// Add-ons can be added to engines onwin installed itself (Engines/<id>) or a developer's writable engine;
    /// never inside an app bundle (that would break its signature).
    public static func canInstall(into engine: Engine) -> Bool {
        let path = engine.root.standardizedFileURL.path
        if path.contains(".app/Contents/") { return false }
        let share = engine.root.appendingPathComponent("share/wine")
        return FileManager.default.isWritableFile(atPath: share.path)
    }

    /// Downloads and unpacks the missing `addons` into the engine; one at a time for the whole app, so two
    /// spaces that need Mono at once download it once. Returns true when something was installed (then every
    /// space is updated at its next start).
    @discardableResult
    public static func install(_ addons: [EngineAddon], into engine: Engine,
                               progress: @escaping ProgressHandler) async throws -> Bool {
        try await AddonLock.shared.run {
            let todo = missing(addons, in: engine)
            guard !todo.isEmpty else { return false }
            guard canInstall(into: engine) else {
                throw OnwinError("Не удалось добавить \(todo.map(\.title).joined(separator: ", ")) в движок Wine: нет прав на запись в \(engine.root.path).")
            }
            let cache = OnwinPaths.cache.appendingPathComponent("Addons", isDirectory: true)
            for (index, addon) in todo.enumerated() {
                try Task.checkCancellation()
                if todo.count > 1 { progress(.status("[\(index + 1)/\(todo.count)] \(addon.title)")) }
                let archive = try await Updater.download(addon.url, sha256: addon.sha256, title: addon.title,
                                                         name: addon.archiveName, into: cache, progress: progress)
                progress(InstallProgress(message: "Распаковываю \(addon.title)…", fraction: nil))
                try await unpack(archive, addon: addon, into: engine)
                try? FileManager.default.removeItem(at: archive)
            }
            touchWineInf(of: engine)
            progress(InstallProgress(message: "\(todo.map(\.title).joined(separator: ", ")) — готово", fraction: 1))
            return true
        }
    }

    static func unpack(_ archive: URL, addon: EngineAddon, into engine: Engine) async throws {
        let fm = FileManager.default
        let groupDir = engine.root.appendingPathComponent("share/wine/\(addon.group)", isDirectory: true)
        try fm.createDirectory(at: groupDir, withIntermediateDirectories: true)
        // Hidden staging folder next to the target: Wine never sees a half-unpacked add-on.
        let staging = groupDir.appendingPathComponent(".install-\(addon.folder)", isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let r = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/tar"), arguments: ["-xf", archive.path, "-C", staging.path])
        let unpacked = staging.appendingPathComponent(addon.folder, isDirectory: true)
        guard r.status == 0, OnwinPaths.isDirectory(unpacked) else {
            throw OnwinError("Не удалось распаковать \(addon.title): \(r.output.suffix(300))")
        }
        let target = addon.directory(in: engine)
        try? fm.removeItem(at: target)
        try fm.moveItem(at: unpacked, to: target)
    }

    /// wineboot updates a space when `.update-timestamp` differs from wine.inf's mtime (WineRunner+PrefixUpdate).
    static func touchWineInf(of engine: Engine) {
        let inf = engine.root.appendingPathComponent("share/wine/wine.inf")
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: inf.path)
    }

    /// Engine update: the new engine (staged, not yet in place) keeps the add-ons the old one had downloaded,
    /// when Wine expects the same versions (the folder names carry them). Moves the folders (same disk).
    static func carryOver(from old: URL, to staged: URL) {
        let fm = FileManager.default
        for group in ["mono", "gecko"] {
            let from = old.appendingPathComponent("share/wine/\(group)", isDirectory: true)
            let to = staged.appendingPathComponent("share/wine/\(group)", isDirectory: true)
            for name in (try? fm.contentsOfDirectory(atPath: from.path)) ?? [] {
                guard EngineAddon.allCases.contains(where: { $0.group == group && $0.folder == name }) else { continue }
                let target = to.appendingPathComponent(name)
                guard !fm.fileExists(atPath: target.path) else { continue }
                try? fm.createDirectory(at: to, withIntermediateDirectories: true)
                try? fm.moveItem(at: from.appendingPathComponent(name), to: target)
            }
        }
    }
}

/// Serializes add-on installs (two spaces needing Mono at once download it once).
private actor AddonLock {
    static let shared = AddonLock()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        while busy { await withCheckedContinuation { waiters.append($0) } }
        busy = true
        defer {
            busy = false
            if !waiters.isEmpty { waiters.removeFirst().resume() }
        }
        return try await body()
    }
}
