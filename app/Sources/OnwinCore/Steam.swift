import Foundation

/// A game installed by the Windows Steam client inside a space (from `steamapps/appmanifest_<id>.acf`).
public struct SteamGame: Identifiable, Hashable, Sendable {
    public var appID: Int
    public var name: String
    /// `steamapps/common/<installdir>` of its library.
    public var installDirectory: URL
    /// The library folder (the one holding `steamapps`).
    public var library: URL
    /// `StateFlags` of the manifest: 4 = fully installed; other bits mean update/download in progress.
    public var stateFlags: Int
    public var sizeOnDisk: Int64?
    public var lastPlayed: Date?

    public var id: Int { appID }
    /// The game files are there (it may still have an update pending).
    public var isFullyInstalled: Bool { stateFlags & 4 != 0 }
    /// Downloading, update required or queued, validating… (anything but plain "installed").
    public var isBusy: Bool { stateFlags != 4 }
}

/// The Windows Steam client of a space.
public struct SteamInstallation: Hashable, Sendable {
    /// Unix path of the Steam folder (holds steam.exe and steamapps).
    public var root: URL
    public var steamExe: URL { root.appendingPathComponent("steam.exe") }
}

/// Steam inside spaces: finds the client, lists installed games and builds the commands that
/// launch or install them: installs go through Valve's public `steam://install/<id>` URL, games are
/// found from Steam's own `appmanifest_<id>.acf` files.
public enum Steam {
    /// Valve's "Steamworks Common Redistributables": a pseudo-app every Steam install has.
    static let hiddenAppIDs: Set<Int> = [228980]

    /// Where SteamSetup.exe installs by default, then what the registry says.
    public static func installation(in space: Space) -> SteamInstallation? {
        var candidates = [#"C:\Program Files (x86)\Steam"#, #"C:\Program Files\Steam"#]
        // HKCU\Software\Valve\Steam "SteamPath" (written by the client as "c:/program files (x86)/steam")
        // and HKLM\Software\Wow6432Node\Valve\Steam "InstallPath".
        if let key = WineRegistry.key(#"Software\Valve\Steam"#, in: WineRegistry.userHive(of: space)),
           let path = key["SteamPath"]?.text { candidates.append(path.replacingOccurrences(of: "/", with: "\\")) }
        for path in [#"Software\Wow6432Node\Valve\Steam"#, #"Software\Valve\Steam"#] {
            if let key = WineRegistry.key(path, in: WineRegistry.machineHive(of: space)),
               let p = key["InstallPath"]?.text { candidates.append(p) }
        }
        for windows in candidates {
            guard let unix = space.unixPath(forWindowsPath: windows) else { continue }
            if let exe = caseInsensitiveChild(of: unix, named: "steam.exe") {
                return SteamInstallation(root: exe.deletingLastPathComponent())
            }
        }
        return nil
    }

    /// Library folders (each holds `steamapps`), the Steam folder first. From `steamapps/libraryfolders.vdf`:
    /// the current format is `"libraryfolders" { "0" { "path" "C:\\…" "apps" {…} } … }`,
    /// the pre-2021 one `"LibraryFolders" { "1" "D:\\SteamLibrary" }`.
    public static func libraryFolders(of steam: SteamInstallation, in space: Space) -> [URL] {
        var result = [steam.root]
        var seen: Set<String> = [steam.root.standardizedFileURL.path.lowercased()]
        let vdfURLs = [steam.root.appendingPathComponent("steamapps/libraryfolders.vdf"),
                       steam.root.appendingPathComponent("config/libraryfolders.vdf")]
        for url in vdfURLs {
            guard let kv = try? KeyValues.parse(contentsOf: url), let top = kv.entries.first?.value else { continue }
            for entry in top.entries where Int(entry.key) != nil {
                let windows: String?
                switch entry.value {
                case .string(let s): windows = s
                case .section: windows = entry.value["path"]?.string
                }
                guard let windows, let unix = unixPath(windows, in: space) else { continue }
                let key = unix.standardizedFileURL.path.lowercased()
                if seen.insert(key).inserted, OnwinPaths.isDirectory(unix) { result.append(unix) }
            }
        }
        return result
    }

    /// Installed games of a space, sorted by name. Empty when there is no Steam.
    public static func games(in space: Space) -> [SteamGame] {
        guard let steam = installation(in: space) else { return [] }
        return games(of: steam, in: space)
    }

    public static func games(of steam: SteamInstallation, in space: Space) -> [SteamGame] {
        var games: [Int: SteamGame] = [:]
        let fm = FileManager.default
        for library in libraryFolders(of: steam, in: space) {
            guard let steamapps = caseInsensitiveChild(of: library, named: "steamapps") else { continue }
            let files = (try? fm.contentsOfDirectory(at: steamapps, includingPropertiesForKeys: nil)) ?? []
            for file in files {
                let name = file.lastPathComponent.lowercased()
                guard name.hasPrefix("appmanifest_"), name.hasSuffix(".acf"),
                      var game = manifest(file, library: library, steamapps: steamapps) else { continue }
                if hiddenAppIDs.contains(game.appID) { continue }
                if let existing = games[game.appID], existing.isFullyInstalled, !game.isFullyInstalled { continue }
                if game.name.isEmpty { game.name = "Steam App \(game.appID)" }
                games[game.appID] = game
            }
        }
        return games.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Reads one `appmanifest_<id>.acf`.
    public static func manifest(_ url: URL, library: URL, steamapps: URL? = nil) -> SteamGame? {
        guard let kv = try? KeyValues.parse(contentsOf: url), let state = kv["AppState"],
              let appID = state["appid"]?.int else { return nil }
        let apps = steamapps ?? library.appendingPathComponent("steamapps")
        let dirName = state["installdir"]?.string ?? ""
        let common = caseInsensitiveChild(of: apps, named: "common") ?? apps.appendingPathComponent("common")
        let dir = dirName.isEmpty ? common
            : (caseInsensitiveChild(of: common, named: dirName) ?? common.appendingPathComponent(dirName))
        let lastPlayed = state["LastPlayed"]?.int.flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil }
        return SteamGame(appID: appID, name: state["name"]?.string ?? "", installDirectory: dir, library: library,
                         stateFlags: state["StateFlags"]?.int ?? 0,
                         sizeOnDisk: state["SizeOnDisk"]?.string.flatMap { Int64($0) }, lastPlayed: lastPlayed)
    }

    // MARK: Commands (Wine arguments)

    /// `steam.exe -applaunch <id>`: starts Steam if needed (it asks to log in the first time) and then the game.
    public static func launchArguments(for appID: Int, steam: SteamInstallation, extra: [String] = []) -> [String] {
        [steam.steamExe.path, "-applaunch", String(appID)] + extra
    }

    /// Opens a `steam://` URL in the space's Steam (`steam://install/<id>`, `steam://validate/<id>`…).
    public static func urlArguments(_ url: String, steam: SteamInstallation) -> [String] {
        [steam.steamExe.path, url]
    }

    public static func installURL(_ appID: Int) -> String { "steam://install/\(appID)" }
    public static func validateURL(_ appID: Int) -> String { "steam://validate/\(appID)" }
    public static func uninstallURL(_ appID: Int) -> String { "steam://uninstall/\(appID)" }
    public static func storeURL(_ appID: Int) -> String { "steam://store/\(appID)" }

    /// Cover art Steam has cached for the game (portrait cover, else header / hero / logo), for the program grid.
    /// See `SteamGameArt` (SteamArt.swift) for the layouts.
    public static func artwork(for game: SteamGame, steam: SteamInstallation) -> URL? {
        let found = art(for: game.appID, steam: steam)
        return found.cover ?? found.header ?? found.hero ?? found.logo
    }

    // MARK: Helpers

    private static func unixPath(_ windows: String, in space: Space) -> URL? {
        let w = windows.replacingOccurrences(of: "/", with: "\\")
        return space.unixPath(forWindowsPath: w)
    }

    static func caseInsensitiveChild(of dir: URL, named name: String) -> URL? {
        let exact = dir.appendingPathComponent(name)
        if OnwinPaths.exists(exact) { return exact }
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return entries.first { $0.caseInsensitiveCompare(name) == .orderedSame }.map { dir.appendingPathComponent($0) }
    }
}

extension Steam {
    /// Opens `steam://install/<id>` in the space's Steam and returns without waiting: the download
    /// happens in Steam (it may first update itself and ask to log in).
    @discardableResult
    public static func requestInstall(appID: Int, name: String, in space: Space,
                                      progress: @escaping ProgressHandler) async throws -> RunningProgram {
        guard let steam = installation(in: space) else {
            throw OnwinError("В пространстве «\(space.name)» нет Steam: сначала установите Steam из каталога.")
        }
        progress(InstallProgress(message: "Открываю установку «\(name)» в Steam…", fraction: nil))
        let program = try await MainActor.run {
            try WineRunner(space: space).launch(wineArguments: urlArguments(installURL(appID), steam: steam),
                                                  title: "Steam — установка \(name)",
                                                  workingDirectory: steam.root)
        }
        progress(InstallProgress(message: "Steam открыт: подтвердите установку «\(name)» в его окне. Игра появится в разделе «Игры Steam» пространства.",
                                 fraction: 1))
        return program
    }
}
