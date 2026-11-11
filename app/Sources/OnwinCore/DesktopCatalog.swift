import Foundation

// «Рабочий стол»: every launchable program of every space in one list.
//
//   DesktopCatalog.items(spaces:programs:userRecipeLaunchPaths:) -> [DesktopItem]
//
// Per space it takes the ProgramScanner list (pinned programs — including the ones catalog recipes and
// user recipes pinned when they were installed — then Start Menu and Public Desktop shortcuts) and the
// games of the space's Windows Steam (Steam.swift). Deduplication inside a space:
//   • a Start Menu / desktop shortcut whose target lies in a Steam game's folder is the game itself:
//     the Steam tile stays (it starts through Steam, so DRM / cloud saves work);
//   • a *pinned* program in a game's folder wins over the game's Steam tile (the user pinned it on purpose,
//     often with own run settings);
//   • the same name twice in one space is shown once (pinned first, then Steam, then shortcuts).
// The same program in two spaces stays twice: the caption tells the spaces apart.
// Does file-system work (Steam manifests, user recipes): call it off the main thread.

/// One tile of the desktop.
public struct DesktopItem: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case program(SpaceProgram)
        case steamGame(SteamGame)
    }

    /// Where the item comes from (shown by `onwinctl desktop`, used for the tile's hint).
    public enum Source: String, Hashable, Sendable, CaseIterable {
        case recipe, userRecipe, pinned, steam, startMenu, desktopShortcut

        public var displayName: String {
            switch self {
            case .recipe: return "Каталог"
            case .userRecipe: return "Мои приложения"
            case .pinned: return "Закреплена"
            case .steam: return "Steam"
            case .startMenu: return "Меню «Пуск»"
            case .desktopShortcut: return "Ярлык рабочего стола"
            }
        }

        /// Short id for the command line.
        public var key: String { rawValue }
    }

    /// Stable across runs (desktop.json keys): "<space UUID>/program/<program id>" or "<space UUID>/steam/<appid>".
    public var id: String
    public var name: String
    public var space: Space
    public var kind: Kind
    public var source: Source

    public var spaceID: UUID { space.id }
    public var spaceName: String { space.name }

    public var program: SpaceProgram? {
        if case .program(let p) = kind { return p }
        return nil
    }

    public var steamGame: SteamGame? {
        if case .steamGame(let g) = kind { return g }
        return nil
    }

    /// What the icon pipeline (AppIcons.swift) resolves for the tile.
    public var iconSubject: AppIconSubject {
        switch kind {
        case .program(let p): return .program(p, space: space)
        case .steamGame(let g): return .steamGame(appID: g.appID, space: space, style: .icon)
        }
    }

    /// SF Symbol of the placeholder tile while (or when no) icon is found.
    public var placeholderSymbol: String {
        switch kind {
        case .steamGame: return "gamecontroller.fill"
        case .program(let p):
            let lower = p.name.lowercased()
            if lower.contains("steam") || lower.contains("game") || lower.contains("игр") { return "gamecontroller.fill" }
            if ["bat", "cmd"].contains(p.launchFile.pathExtension.lowercased()) { return "terminal.fill" }
            return "macwindow"
        }
    }

    /// False while Steam is still downloading the game (it cannot start yet).
    public var isLaunchable: Bool {
        if case .steamGame(let g) = kind { return g.isFullyInstalled }
        return true
    }

    /// "Загружается" / "Нужно обновление" for Steam games, nil otherwise.
    public var statusText: String? {
        guard case .steamGame(let g) = kind else { return nil }
        if !g.isFullyInstalled { return "Загружается" }
        if g.isBusy { return "Нужно обновление" }
        return nil
    }

    /// Steam's own "last played" (used for «Недавние» when onwin has not started it itself).
    public var lastPlayed: Date? { steamGame?.lastPlayed }

    /// The file «Показать в Finder» selects.
    public var revealTarget: URL {
        switch kind {
        case .program(let p):
            if let exe = p.executable, OnwinPaths.exists(exe) { return exe }
            return p.launchFile
        case .steamGame(let g):
            return OnwinPaths.exists(g.installDirectory) ? g.installDirectory : g.library
        }
    }

    /// Unix paths that identify the item in a started command (to match running programs).
    public var commandPaths: [String] {
        switch kind {
        case .program(let p):
            return [p.launchFile.path, p.executable?.path].compactMap { $0 }
        case .steamGame:
            return []
        }
    }

    /// Does a started Wine command / title belong to this item?
    public func matches(title: String, command: [String]) -> Bool {
        if title == name { return true }
        switch kind {
        case .steamGame(let g):
            if let flag = command.firstIndex(where: { $0.lowercased() == "-applaunch" }), flag + 1 < command.count {
                return Int(command[flag + 1]) == g.appID
            }
            return false
        case .program:
            let paths = Set(commandPaths.map { $0.lowercased() })
            return command.contains { paths.contains($0.lowercased()) }
        }
    }
}

public enum DesktopCatalog {
    public static func itemID(space: UUID, program: SpaceProgram) -> String {
        "\(space.uuidString)/program/\(program.id)"
    }

    public static func itemID(space: UUID, steamAppID: Int) -> String {
        "\(space.uuidString)/steam/\(steamAppID)"
    }

    /// Launch paths (lowercased Windows paths) of the user's own recipes.
    public static func userRecipeLaunchPaths() -> Set<String> {
        Set(UserRecipes.all().compactMap { $0.launchPath?.lowercased() })
    }

    /// All desktop items of all spaces, deduplicated (see the file header), sorted by name.
    /// - Parameters:
    ///   - programs: cached ProgramScanner results per space; missing spaces are scanned.
    ///   - userRecipeLaunchPaths: lowercased launch paths of user recipes; nil reads them from disk.
    public static func items(spaces: [Space], programs: [UUID: [SpaceProgram]] = [:],
                             userRecipeLaunchPaths: Set<String>? = nil) -> [DesktopItem] {
        let userPaths = userRecipeLaunchPaths ?? DesktopCatalog.userRecipeLaunchPaths()
        let catalogPaths = Set(Catalog.apps.filter { $0.category != .user }.compactMap { $0.launchPath?.lowercased() })
        var result: [DesktopItem] = []
        for space in spaces {
            let list = programs[space.id] ?? ProgramScanner.programs(in: space)
            result += items(in: space, programs: list, userPaths: userPaths, catalogPaths: catalogPaths)
        }
        return result.sorted(by: byName)
    }

    public static func byName(_ a: DesktopItem, _ b: DesktopItem) -> Bool {
        let order = a.name.localizedStandardCompare(b.name)
        if order != .orderedSame { return order == .orderedAscending }
        return a.spaceName.localizedStandardCompare(b.spaceName) == .orderedAscending
    }

    static func items(in space: Space, programs: [SpaceProgram], userPaths: Set<String>,
                      catalogPaths: Set<String>) -> [DesktopItem] {
        let games = Steam.games(in: space)
        let gameDirs: [(dir: String, appID: Int)] = games.map { (normalized($0.installDirectory) + "/", $0.appID) }
        func game(of program: SpaceProgram) -> Int? {
            guard let exe = program.executable else { return nil }
            let path = normalized(exe)
            guard path.contains("/steamapps/common/") else { return nil }
            return gameDirs.first { path.hasPrefix($0.dir) }?.appID
        }

        let pinned = programs.filter { if case .pinned = $0.source { return true } else { return false } }
        let shortcuts = programs.filter { if case .pinned = $0.source { return false } else { return true } }
        var gamesTakenByPins = Set<Int>()
        var names = Set<String>()
        var items: [DesktopItem] = []

        func add(_ item: DesktopItem) {
            let key = item.name.trimmingCharacters(in: .whitespaces).lowercased()
            guard names.insert(key).inserted else { return }
            items.append(item)
        }

        for program in pinned {
            if let appID = game(of: program) { gamesTakenByPins.insert(appID) }
            add(DesktopItem(id: itemID(space: space.id, program: program), name: program.name, space: space,
                            kind: .program(program), source: pinnedSource(program, in: space,
                                                                          userPaths: userPaths, catalogPaths: catalogPaths)))
        }
        for g in games where !gamesTakenByPins.contains(g.appID) {
            add(DesktopItem(id: itemID(space: space.id, steamAppID: g.appID), name: g.name, space: space,
                            kind: .steamGame(g), source: .steam))
        }
        for program in shortcuts where game(of: program) == nil {
            let source: DesktopItem.Source
            if case .desktop = program.source { source = .desktopShortcut } else { source = .startMenu }
            add(DesktopItem(id: itemID(space: space.id, program: program), name: program.name, space: space,
                            kind: .program(program), source: source))
        }
        return items
    }

    private static func pinnedSource(_ program: SpaceProgram, in space: Space, userPaths: Set<String>,
                                     catalogPaths: Set<String>) -> DesktopItem.Source {
        guard case .pinned(let id) = program.source,
              let entry = space.config.programs.first(where: { $0.id == id }) else { return .pinned }
        let path = entry.windowsPath.lowercased()
        if userPaths.contains(path) { return .userRecipe }
        if catalogPaths.contains(path) { return .recipe }
        return .pinned
    }

    private static func normalized(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path.lowercased()
    }
}
