import AppKit
import Foundation
import Observation
import OnwinCore

// MARK: - Launchers and opened URLs (read this if you add UI for launchers)
//
//   AppModel.shared.handleOpened(_ urls: [URL])     everything macOS hands the app: onwin://run URLs
//                                                    (launchers), .onwinspace archives (restore), files
//   func handleLaunchURL(_ url: URL) -> Bool         onwin://run?space=&program=&file= → runs the program
//   func createLauncher(for program: SpaceProgram, in space: Space)     «Создать ярлык в Launchpad»
//   func removeLauncher(for program: SpaceProgram, in space: Space)
//   func launcher(for program: SpaceProgram, in space: Space) -> LauncherInfo?   (cached, LauncherStore)
//   func setAutoLaunchers(_ on: Bool, for spaceID: UUID)                  space option, syncs right away
//   func syncLaunchers(of spaceID: UUID)            automatic launchers + folder rename; called after
//                                                    refreshPrograms (installers finishing, reload)
//   func removeLaunchers(of spaceID: UUID)          when a space is deleted
// Core: LauncherBuilder / LaunchRequest (OnwinCore/Launchers.swift), StartMenuHook (wineshelllink).

/// Launchers on disk, per space, so menus can show «Создать…» or «Удалить…» without disk reads.
@MainActor
@Observable
final class LauncherStore {
    static let shared = LauncherStore()

    private(set) var bySpace: [UUID: [LauncherInfo]] = [:]
    @ObservationIgnored private var syncing = Set<UUID>()
    @ObservationIgnored private var resyncRequested = Set<UUID>()

    func set(_ launchers: [LauncherInfo], for spaceID: UUID) {
        bySpace[spaceID] = launchers.isEmpty ? nil : launchers
    }

    /// Runs one sync per space at a time; a request during a sync re-runs it afterwards.
    func beginSync(_ spaceID: UUID) -> Bool {
        if syncing.contains(spaceID) {
            resyncRequested.insert(spaceID)
            return false
        }
        syncing.insert(spaceID)
        return true
    }

    /// True when another sync was requested meanwhile.
    func endSync(_ spaceID: UUID) -> Bool {
        syncing.remove(spaceID)
        return resyncRequested.remove(spaceID) != nil
    }
}

extension AppModel {
    // MARK: Opened URLs

    /// Entry point for URLs and files macOS opens with onwin (onOpenURL, application(_:open:)).
    func handleOpened(_ urls: [URL]) {
        var files: [URL] = []
        for url in urls {
            if url.scheme?.lowercased() == LaunchRequest.scheme {
                _ = handleLaunchURL(url)
            } else if url.isFileURL, ["onwinspace", "onwinbottle"].contains(url.pathExtension.lowercased()) {
                Task { await restore(from: url) }
            } else if url.isFileURL, url.pathExtension.lowercased() == UserRecipe.fileExtension {
                openUserRecipeFile(url)   // review in the editor; nothing runs (AppModel+UserRecipes.swift)
            } else {
                files.append(url)
            }
        }
        if !files.isEmpty { openFiles(files) }
    }

    /// `onwin://run?...` from a launcher: runs the program in its space.
    @discardableResult
    func handleLaunchURL(_ url: URL) -> Bool {
        guard let request = LaunchRequest(url: url) else {
            report("onwin не понимает адрес \(url.absoluteString).")
            return false
        }
        guard hasEngine else {
            report(AppModel.noEngineMessage)
            return false
        }
        do {
            let (space, program) = try request.resolve(in: spaces) { [weak self] b in
                self?.programs(in: b) ?? ProgramScanner.programs(in: b)
            }
            return run(program: program, in: space) != nil || isPreparingLaunch(in: space.id)
        } catch {
            // The cached list may be older than the shortcut: rescan once.
            if let space = spaces.first(where: { $0.id.uuidString.caseInsensitiveCompare(request.space) == .orderedSame }) {
                refreshPrograms(of: space.id)
                if let resolved = try? request.resolve(in: spaces, programs: { [weak self] b in
                    self?.programs(in: b) ?? []
                }) {
                    return run(program: resolved.1, in: resolved.0) != nil || isPreparingLaunch(in: resolved.0.id)
                }
            }
            report(error)
            return false
        }
    }

    // MARK: Launchers

    func launcher(for program: SpaceProgram, in space: Space) -> LauncherInfo? {
        LauncherStore.shared.bySpace[space.id]?.first { $0.programID == program.id }
    }

    func launchers(of spaceID: UUID) -> [LauncherInfo] {
        LauncherStore.shared.bySpace[spaceID] ?? []
    }

    /// «Создать ярлык в Launchpad»: builds ~/Applications/onwin/<space>/<program>.app.
    func createLauncher(for program: SpaceProgram, in space: Space) {
        let current = self.space(id: space.id) ?? space
        let root = LauncherBuilder.defaultRoot
        backgroundActivity = "Создаю ярлык «\(program.name)»…"
        Task.detached(priority: .userInitiated) {
            let outcome: Result<URL, Error> = Result { try LauncherBuilder.create(for: program, in: current, root: root) }
            let list = LauncherBuilder.launchers(for: current.id, root: root)
            await MainActor.run {
                let model = AppModel.shared
                if model.backgroundActivity?.hasPrefix("Создаю ярлык") == true { model.backgroundActivity = nil }
                LauncherStore.shared.set(list, for: current.id)
                switch outcome {
                case .success(let app):
                    NSWorkspace.shared.activateFileViewerSelecting([app])
                case .failure(let error):
                    model.report("Не удалось создать ярлык «\(program.name)»: \(error.localizedDescription)")
                }
            }
        }
    }

    func removeLauncher(for program: SpaceProgram, in space: Space) {
        guard let launcher = launcher(for: program, in: space) else { return }
        do {
            try LauncherBuilder.remove(launcher)
        } catch {
            report("Не удалось удалить ярлык «\(launcher.name)»: \(error.localizedDescription)")
        }
        LauncherStore.shared.set(LauncherBuilder.launchers(for: space.id), for: space.id)
    }

    /// «Создавать ярлыки автоматически».
    func setAutoLaunchers(_ on: Bool, for spaceID: UUID) {
        updateConfig(of: spaceID) { $0.autoLaunchers = on }
        if on { syncLaunchers(of: spaceID) }
    }

    /// Creates / removes automatic launchers and moves launchers after a space rename.
    /// Cheap when nothing changed; runs off the main thread.
    func syncLaunchers(of spaceID: UUID) {
        guard let space = space(id: spaceID) else { return }
        let store = LauncherStore.shared
        guard store.beginSync(spaceID) else { return }
        let list = self.programs(in: space)
        let root = LauncherBuilder.defaultRoot
        Task.detached(priority: .utility) {
            let result = LauncherBuilder.sync(space, programs: list, root: root)
            let launchers = LauncherBuilder.launchers(for: space.id, root: root)
            await MainActor.run {
                store.set(launchers, for: space.id)
                if !result.errors.isEmpty {
                    AppModel.shared.report("Ярлыки пространства «\(space.name)»: " + result.errors.prefix(3).joined(separator: "; "))
                }
                if store.endSync(space.id) { AppModel.shared.syncLaunchers(of: space.id) }
            }
        }
    }

    /// Launchers of a deleted space go to the Trash too.
    func removeLaunchers(of spaceID: UUID) {
        let root = LauncherBuilder.defaultRoot
        Task.detached(priority: .utility) {
            LauncherBuilder.removeAll(for: spaceID, root: root)
            await MainActor.run { LauncherStore.shared.set([], for: spaceID) }
        }
    }
}
