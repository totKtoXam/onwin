import AppKit
import Foundation
import Observation
import OnwinCore

// MARK: - «Рабочий стол» (read this if you add UI for the desktop)
//
// The main screen (SidebarItem.desktop, selected on launch): every launchable program of every space.
// Core: OnwinCore/DesktopCatalog.swift (aggregation + dedup → [DesktopItem]), DesktopStore.swift
// (~/Library/Application Support/onwin/desktop.json: last launches, hidden items).
// Views: Views/DesktopView.swift (grid, top bar, running strip), Views/DesktopSheets.swift (file sheet).
//
//   DesktopModel.shared            observable: items, state (DesktopState), highlighted ids, fileRequest
//   AppModel.desktopRefreshKey     changes when spaces / programs / running programs / the task change
//   AppModel.refreshDesktop() async   re-aggregates off the main thread (ProgramScanner cache + Steam scan)
//   AppModel.launch(_ item:)       runs the item in its space (run(program:in:) / launchSteamGame) and records it
//   AppModel.runWithOptions(_ item:)  «Запустить с параметрами…» (RunOptionsSheet via ProgramDialogs)
//   AppModel.setHidden(_:_:), desktopLastUsed(_:), desktopRunning(_:)
//   AppModel.desktopInstallRecipe(_ id:)   one-click catalog install (Steam / Epic / GOG / Battle.net)
//   AppModel.desktopChooseInstaller()      «Из файла…»: NSOpenPanel → DesktopFileSheet
//   AppModel.desktopHandleDrop(_ urls:)    files dropped on the desktop → DesktopFileSheet (one file) or the
//                                          shell's «в каком пространстве?» chooser (several)
//   AppModel.desktopPerform(_:action:target:…:pin:) async   creates the space if needed, then runs (and pins) or installs;
//                                          after an install the new programs are highlighted on the desktop
//   AppModel.desktopQuit(_ program:force:)  «Завершить» in the «Запущено» strip

/// What to do with a file put on the desktop.
enum DesktopFileAction: Hashable {
    case run
    case install
}

/// A file waiting for «новое или существующее пространство?» (DesktopFileSheet).
struct DesktopFileRequest: Identifiable, Equatable {
    let id = UUID()
    var file: URL
    /// Actions the sheet offers, the first one preselected.
    var actions: [DesktopFileAction]
}

@MainActor
@Observable
final class DesktopModel {
    static let shared = DesktopModel()

    private(set) var items: [DesktopItem] = []
    private(set) var hasLoaded = false
    private(set) var state: DesktopState = DesktopStore.load()
    /// Programs that appeared after an install started from the desktop (accent border, «Новое»).
    var highlighted: Set<String> = []
    /// Presents DesktopFileSheet.
    var fileRequest: DesktopFileRequest?
    /// Tiles whose program really runs, found among the Wine processes (polled every few seconds):
    /// Steam games are started by Steam, and Steam itself is often started by a game or by
    /// `steam.exe -applaunch`, so onwin's own process tracking alone is not enough.
    private(set) var runningSteamItems: Set<String> = []
    @ObservationIgnored fileprivate var steamMonitor: Task<Void, Never>?

    fileprivate func startSteamMonitor() {
        guard steamMonitor == nil else { return }
        steamMonitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // (tile id, space path, lowercased match key, is a folder key)
                let keys = self.items.compactMap { item -> (String, String, String)? in
                    switch item.kind {
                    case .steamGame(let g):
                        return (item.id, item.space.url.standardizedFileURL.path,
                                "\\steamapps\\common\\" + g.installDirectory.lastPathComponent.lowercased() + "\\")
                    case .program(let p):
                        guard let exe = p.executable, exe.pathExtension.lowercased() == "exe" else { return nil }
                        return (item.id, item.space.url.standardizedFileURL.path,
                                item.space.windowsPath(forUnixPath: exe).lowercased())
                    }
                }
                var running: Set<String> = []
                if !keys.isEmpty {
                    let entries = await WineProcesses.snapshot()
                    var keyCount: [String: Int] = [:]
                    for (_, _, key) in keys { keyCount[key, default: 0] += 1 }
                    for (id, spacePath, key) in keys {
                        let procs = entries.filter { $0.command.contains(key) }
                        guard !procs.isEmpty else { continue }
                        // The same path in several spaces: the process's working directory decides.
                        if keyCount[key, default: 0] < 2 { running.insert(id); continue }
                        for p in procs {
                            if let cwd = await WineProcesses.workingDirectory(of: p.pid), cwd.hasPrefix(spacePath) {
                                running.insert(id)
                                break
                            }
                        }
                    }
                }
                if running != self.runningSteamItems { self.runningSteamItems = running }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    @ObservationIgnored fileprivate var generation = 0
    @ObservationIgnored fileprivate var highlightReset: Task<Void, Never>?

    fileprivate func setItems(_ new: [DesktopItem]) {
        if new != items { items = new }
        hasLoaded = true
    }

    fileprivate func update(_ change: (inout DesktopState) -> Void) {
        var copy = state
        change(&copy)
        guard copy != state else { return }
        state = copy
        do {
            try DesktopStore.save(copy)
        } catch {
            AppModel.shared.report("Не удалось сохранить \(DesktopStore.file.lastPathComponent): \(error.localizedDescription)")
        }
    }

    fileprivate func highlight(_ ids: Set<String>) {
        highlightReset?.cancel()
        highlighted = ids
        guard !ids.isEmpty else { return }
        highlightReset = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            guard !Task.isCancelled else { return }
            self?.highlighted = []
        }
    }
}

extension AppModel {
    var desktop: DesktopModel { DesktopModel.shared }

    /// Changes whenever the desktop may have to be re-aggregated.
    var desktopRefreshKey: String {
        var parts = spaces.map { "\($0.id.uuidString):\($0.name):\($0.config.programs.count)" }
        for (id, list) in programsBySpace {
            parts.append("\(id.uuidString)=\(list.count):\(list.map(\.id).joined(separator: ",").hashValue)")
        }
        parts.append("running:\(ProcessTracker.shared.running.count)")
        parts.append("idle:\(activeTask == nil)")
        parts.append("recipes:\(UserRecipeStore.shared.recipes.count)")
        return parts.sorted().joined(separator: "|")
    }

    // MARK: Aggregation

    func refreshDesktop() async {
        let d = desktop
        d.generation += 1
        let generation = d.generation
        let spaces = self.spaces
        let programs = programsBySpace
        let userPaths = Set(UserRecipeStore.shared.recipes.compactMap { $0.launchPath?.lowercased() })
        let items = await Task.detached(priority: .utility) {
            DesktopCatalog.items(spaces: spaces, programs: programs, userRecipeLaunchPaths: userPaths)
        }.value
        guard generation == d.generation else { return }
        d.setItems(items)
        d.startSteamMonitor()
        noteRunningLaunches()
        if !spaces.isEmpty {
            let ids = Set(spaces.map(\.id))
            d.update { state in state.prune(keepingSpaces: ids) }
        }
    }

    /// Is the item running? Steam games: their own process (Steam starts them), everything else:
    /// programs started from this onwin instance.
    func desktopIsRunning(_ item: DesktopItem) -> Bool {
        if case .steamGame = item.kind { return desktop.runningSteamItems.contains(item.id) }
        return desktop.runningSteamItems.contains(item.id) || !desktopRunning(item).isEmpty
    }

    /// Items currently running (started from this onwin instance).
    func desktopRunning(_ item: DesktopItem) -> [RunningProgram] {
        ProcessTracker.shared.running(in: item.spaceID).filter {
            item.matches(title: $0.title, command: $0.command) && desktopItem(for: $0)?.id == item.id
        }
    }

    /// The desktop item a running program belongs to. A Steam game started with `steam.exe -applaunch`
    /// also matches the space's Steam tile (same steam.exe path): the game wins, then an exact title.
    func desktopItem(for program: RunningProgram) -> DesktopItem? {
        let candidates = desktop.items.filter {
            $0.spaceID == program.spaceID && $0.matches(title: program.title, command: program.command)
        }
        return candidates.first { $0.steamGame != nil }
            ?? candidates.first { $0.name == program.title }
            ?? candidates.first
    }

    /// Last start by onwin, or Steam's own «last played», whichever is newer.
    func desktopLastUsed(_ item: DesktopItem) -> Date? {
        [desktop.state.lastLaunched[item.id], item.lastPlayed].compactMap { $0 }.max()
    }

    func isHiddenOnDesktop(_ item: DesktopItem) -> Bool {
        desktop.state.hidden.contains(item.id)
    }

    func setHidden(_ item: DesktopItem, _ hidden: Bool) {
        desktop.update { state in
            if hidden { state.hidden.insert(item.id) } else { state.hidden.remove(item.id) }
        }
    }

    /// Programs started anywhere in onwin (space page, Launchpad) count as «recently used» too.
    func noteRunningLaunches() {
        var seen: [String: Date] = [:]
        for program in ProcessTracker.shared.programs {
            guard let item = desktopItem(for: program) else { continue }
            seen[item.id] = max(seen[item.id] ?? .distantPast, program.started)
        }
        guard !seen.isEmpty else { return }
        desktop.update { state in
            for (id, date) in seen where (state.lastLaunched[id] ?? .distantPast) < date {
                state.lastLaunched[id] = date
            }
        }
    }

    // MARK: Launching

    func launch(_ item: DesktopItem) {
        guard hasEngine else { report(AppModel.noEngineMessage); return }
        guard let space = space(id: item.spaceID) else {
            report("Пространства «\(item.spaceName)» больше нет.")
            return
        }
        guard item.isLaunchable else {
            report("«\(item.name)» ещё загружается в Steam — запустить можно, когда загрузка закончится.")
            return
        }
        let started: RunningProgram?
        switch item.kind {
        case .program(let program): started = run(program: program, in: space)
        case .steamGame(let game): started = launchSteamGame(game, in: space)
        }
        if started != nil || isPreparingLaunch(in: space.id) {   // deferred: components first
            desktop.update { $0.lastLaunched[item.id] = Date() }
        }
    }

    func runWithOptions(_ item: DesktopItem) {
        guard hasEngine else { report(AppModel.noEngineMessage); return }
        switch item.kind {
        case .program(let program): ProgramDialogs.shared.request = .runWithOptions(item.spaceID, .program(program))
        case .steamGame(let game): ProgramDialogs.shared.request = .runWithOptions(item.spaceID, .steamGame(game))
        }
    }

    /// «Завершить» in the «Запущено» strip: SIGTERM (force: SIGKILL) to the started Wine process.
    func desktopQuit(_ program: RunningProgram, force: Bool) {
        if !RunningProgramControl.terminate(program, force: force) {
            report("Не удалось завершить «\(program.title)». Попробуйте «Завершить всё в пространстве».")
        }
    }

    // MARK: Installing

    /// One-click catalog install (Steam, Epic Games, GOG Galaxy, Battle.net): the recipe's own space.
    func desktopInstallRecipe(_ id: String) {
        guard let recipe = Catalog.app(id) else { return }
        Task { @MainActor in
            await self.highlightingNewPrograms {
                _ = await self.install(recipe: recipe, into: nil)
            }
        }
    }

    /// Spaces in which a catalog recipe's program is already installed.
    /// Same rule as the catalog cards: the recipe's launchPath exists on disk (MainProgramViews.swift).
    func desktopSpaces(with recipeID: String) -> [Space] {
        guard let recipe = Catalog.app(recipeID) else { return [] }
        return spacesWithInstalled(recipe)
    }

    /// «Из файла…»: picks an installer, then asks for the space (DesktopFileSheet).
    func desktopChooseInstaller() {
        guard hasEngine else { report(AppModel.noEngineMessage); return }
        guard let url = OnwinPanels.chooseFile(title: "Установить программу",
                                               message: "Выберите установщик Windows-программы (.exe или .msi)",
                                               prompt: "Выбрать", extensions: ["exe", "msi"]) else { return }
        desktop.fileRequest = DesktopFileRequest(file: url, actions: [.install])
    }

    /// Files dropped on the desktop. One file → DesktopFileSheet; several → the shell's space chooser.
    @discardableResult
    func desktopHandleDrop(_ urls: [URL]) -> Bool {
        let files = urls.filter(WineFileTypes.isRunnable)
        guard !files.isEmpty else { return false }
        guard hasEngine else { report(AppModel.noEngineMessage); return true }
        guard files.count == 1, let file = files.first else {
            openFiles(files)
            return true
        }
        desktop.fileRequest = DesktopFileRequest(file: file, actions: AppModel.desktopActions(for: file))
        return true
    }

    /// .msi installs, .lnk / .bat / .cmd run; an .exe can do both (setup-looking names install first).
    static func desktopActions(for file: URL) -> [DesktopFileAction] {
        switch file.pathExtension.lowercased() {
        case "msi": return [.install]
        case "exe":
            let name = file.deletingPathExtension().lastPathComponent.lowercased()
            let looksLikeSetup = ["setup", "install", "installer", "установ"].contains { name.contains($0) }
            return looksLikeSetup ? [.install, .run] : [.run, .install]
        default: return [.run]
        }
    }

    /// Runs or installs a desktop file in a new space (created first) or an existing one.
    func desktopPerform(_ file: URL, action: DesktopFileAction, target: CatalogTarget, newName: String,
                        windowsVersion: WindowsVersion, backend: GraphicsBackend, pin: Bool = false) async {
        await highlightingNewPrograms {
            let space: Space
            switch target {
            case .existing(let id):
                guard let found = self.space(id: id) else { return }
                space = found
            case .newSpace:
                guard let created = await self.createSpace(name: newName, windowsVersion: windowsVersion,
                                                            backend: backend) else { return }
                space = created
            }
            switch action {
            case .run:
                // «Добавить на рабочий стол»: a portable program gets pinned, so it gets its own tile.
                if pin && ["exe", "bat", "cmd"].contains(file.pathExtension.lowercased()) {
                    self.pinProgram(file, in: space.id)
                }
                self.run(files: [file], in: space)
            case .install:
                // Waits for the installer, rescans, offers «Сохранить в каталог?» (AppModel+UserRecipes.swift).
                await self.installCustom(file: file, in: space)
            }
        }
    }

    /// Runs `work` (an install), brings the desktop back and highlights the programs that appeared.
    private func highlightingNewPrograms(_ work: () async -> Void) async {
        if !desktop.hasLoaded { await refreshDesktop() }   // otherwise everything would look new
        let before = Set(desktop.items.map(\.id))
        await work()
        selection = .desktop
        await refreshDesktop()   // install(recipe:) / installCustom already rescanned the programs (reload)
        let added = Set(desktop.items.map(\.id)).subtracting(before)
        desktop.highlight(added)
    }

    func clearDesktopHighlight() {
        desktop.highlight([])
    }
}
