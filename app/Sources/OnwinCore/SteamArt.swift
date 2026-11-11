import Foundation

/// Artwork the Windows Steam client has cached for one game inside a space.
///
/// Steam keeps library art in `Steam/appcache/librarycache`. Two layouts exist:
///
///     2024+ clients   librarycache/<appid>/library_600x900.jpg   portrait cover (also library_600x900_2x.jpg)
///                     librarycache/<appid>/header.jpg            460×215 capsule
///                     librarycache/<appid>/library_hero.jpg      wide background
///                     librarycache/<appid>/logo.png              transparent title logo
///                     librarycache/<appid>/<sha1>.jpg            32×32 community icon (40 hex digits)
///                     (localized / updated assets can sit one level deeper: <appid>/<hash>/library_600x900.jpg)
///     older clients   librarycache/<appid>_library_600x900.jpg, <appid>_header.jpg, <appid>_logo.png, <appid>_icon.jpg
///
/// The best square icon is the "client icon" Steam writes for desktop / Start Menu shortcuts:
/// `Steam/steam/games/<hash>.ico` (multi-size, up to 256 px), referenced by the `IconFile=` line of the
/// game's `.url` shortcut (`URL=steam://rungameid/<appid>`). Every file is optional: before the
/// first login the cache does not exist at all.
public struct SteamGameArt: Hashable, Sendable {
    /// Portrait 600×900 (or 2×) library capsule.
    public var cover: URL?
    /// 460×215 header capsule.
    public var header: URL?
    public var hero: URL?
    /// Transparent title logo.
    public var logo: URL?
    /// Small square community icon (.jpg).
    public var icon: URL?
    /// High-resolution square shortcut icon (.ico from `steam/games`).
    public var clientIcon: URL?

    public init(cover: URL? = nil, header: URL? = nil, hero: URL? = nil, logo: URL? = nil,
                icon: URL? = nil, clientIcon: URL? = nil) {
        self.cover = cover; self.header = header; self.hero = hero
        self.logo = logo; self.icon = icon; self.clientIcon = clientIcon
    }

    public var isEmpty: Bool { [cover, header, hero, logo, icon, clientIcon].allSatisfy { $0 == nil } }
}

extension Steam {
    /// Art of a game from the Steam folder's library cache (and its shortcuts, when the space is known).
    public static func art(for appID: Int, steam: SteamInstallation, space: Space? = nil) -> SteamGameArt {
        var art = SteamGameArt()
        let id = String(appID)
        let fm = FileManager.default
        if let appcache = caseInsensitiveChild(of: steam.root, named: "appcache"),
           let cache = caseInsensitiveChild(of: appcache, named: "librarycache") {
            // Per-app folder (current clients): top-level files first, then one level of subfolders.
            if let folder = caseInsensitiveChild(of: cache, named: id), OnwinPaths.isDirectory(folder) {
                var files = imageFiles(in: folder)
                for sub in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
                where OnwinPaths.isDirectory(sub) {
                    files += imageFiles(in: sub)
                }
                func named(_ names: [String]) -> URL? {
                    for name in names {
                        if let hit = files.first(where: { $0.lastPathComponent.lowercased() == name }) { return hit }
                    }
                    return nil
                }
                art.cover = named(["library_600x900_2x.jpg", "library_600x900.jpg", "library_capsule.jpg"])
                art.header = named(["header.jpg", "library_header.jpg", "library_header_2x.jpg"])
                art.hero = named(["library_hero.jpg", "library_hero_2x.jpg"])
                art.logo = named(["logo.png", "logo_2x.png"])
                art.icon = files.first { isHashName($0.deletingPathExtension().lastPathComponent)
                    && ["jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }
            }
            // Flat layout of older clients.
            func flat(_ suffixes: [String]) -> URL? {
                for suffix in suffixes {
                    let url = cache.appendingPathComponent("\(id)_\(suffix)")
                    if OnwinPaths.exists(url) { return url }
                }
                return nil
            }
            art.cover = art.cover ?? flat(["library_600x900_2x.jpg", "library_600x900.jpg"])
            art.header = art.header ?? flat(["header.jpg", "library_header.jpg"])
            art.hero = art.hero ?? flat(["library_hero.jpg"])
            art.logo = art.logo ?? flat(["logo.png"])
            art.icon = art.icon ?? flat(["icon.jpg"])
        }
        if let space {
            art.clientIcon = shortcutIcon(for: appID, steam: steam, in: space)
        }
        return art
    }

    /// `IconFile=` of the game's Steam shortcut (Start Menu or desktop `.url` with `steam://rungameid/<id>`).
    public static func shortcutIcon(for appID: Int, steam: SteamInstallation, in space: Space) -> URL? {
        let fm = FileManager.default
        let drive = space.driveC
        var folders = [drive.appendingPathComponent("ProgramData/Microsoft/Windows/Start Menu/Programs")]
        let users = drive.appendingPathComponent("users")
        for user in (try? fm.contentsOfDirectory(atPath: users.path)) ?? [] {
            folders.append(users.appendingPathComponent("\(user)/Desktop"))
            folders.append(users.appendingPathComponent("\(user)/AppData/Roaming/Microsoft/Windows/Start Menu/Programs"))
        }
        let wanted = "steam://rungameid/\(appID)"
        for folder in folders {
            guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: nil) else { continue }
            for case let file as URL in walker where file.pathExtension.lowercased() == "url" {
                guard walker.level <= 3,
                      let text = (try? String(contentsOf: file, encoding: .utf8))
                        ?? (try? String(contentsOf: file, encoding: .windowsCP1252))
                else { continue }
                var url: String?
                var iconFile: String?
                for raw in text.split(whereSeparator: \.isNewline) {
                    let line = raw.trimmingCharacters(in: .whitespaces)
                    if line.lowercased().hasPrefix("url=") { url = String(line.dropFirst(4)) }
                    if line.lowercased().hasPrefix("iconfile=") { iconFile = String(line.dropFirst(9)) }
                }
                guard let url, url.lowercased() == wanted || url.lowercased().hasPrefix(wanted + "/"),
                      let iconFile, !iconFile.isEmpty else { continue }
                if let unix = space.unixPath(forWindowsPath: iconFile), OnwinPaths.exists(unix) { return unix }
            }
        }
        return nil
    }

    /// The Steam game whose install folder holds `file` (a game's own exe pinned or found in the Start Menu).
    public static func game(containing file: URL, in space: Space) -> (steam: SteamInstallation, game: SteamGame)? {
        let path = file.standardizedFileURL.resolvingSymlinksInPath().path.lowercased()
        guard path.contains("/steamapps/common/"), let steam = installation(in: space) else { return nil }
        for game in games(of: steam, in: space) {
            let dir = game.installDirectory.standardizedFileURL.resolvingSymlinksInPath().path.lowercased()
            if path.hasPrefix(dir + "/") { return (steam, game) }
        }
        return nil
    }

    private static func imageFiles(in folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// A SHA-1 file name ("1f2e…", 40 hex digits): the community icon.
    private static func isHashName(_ name: String) -> Bool {
        name.count == 40 && name.allSatisfy(\.isHexDigit)
    }
}
